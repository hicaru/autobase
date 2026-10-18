//! Decision loop: read chain state, decide, simulate, send. Publishes a status snapshot for the API.

use std::sync::{Arc, RwLock};

use alloy::{
    eips::BlockNumberOrTag,
    primitives::{Address, Bytes, U256, aliases::I24},
    providers::Provider,
    rpc::types::TransactionRequest,
    sol_types::{SolCall, SolInterface},
};
use serde::Serialize;
use tracing::{error, info, warn};

use crate::{
    abi::{IAutoBaseVault, IERC20, IUniswapV3Pool},
    config::Config,
    db::Db,
    rpc::{RpcError, RpcPool},
    strategy::{self, Decision, DecisionInput},
    tx::{TxOutcome, TxSender, now_secs},
};

/// Addresses and constants resolved once at startup.
#[derive(Debug, Clone, Serialize)]
pub struct Chain {
    pub vault: Address,
    pub pool: Address,
    pub token0: Address,
    pub token1: Address,
    pub tick_spacing: i32,
    pub keeper: Address,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Status {
    pub updated_at: u64,
    pub block_time: u64,
    pub keeper: Option<Address>,
    pub keeper_balance_eth: f64,
    pub keeper_balance_low: bool,
    pub paused: bool,
    pub tick: i32,
    pub twap_tick: i32,
    pub tick_lower: i32,
    pub tick_upper: i32,
    pub in_range: bool,
    pub position_liquidity: String,
    pub idle0: String,
    pub idle1: String,
    pub idle_value1: f64,
    pub last_rebalance: u64,
    pub base_fee_gwei: f64,
    pub sigma_daily: Option<f64>,
    pub chosen_half_width: i32,
    pub min_half_width: i32,
    pub max_half_width: i32,
    /// |spot − center| / half width, in bps (re-center at `recenter_threshold_bps`).
    pub trigger_distance_bps: i64,
    pub recenter_threshold_bps: u16,
    pub decision: Option<Decision>,
    pub last_tx: Option<String>,
    pub last_error: Option<String>,
}

pub type SharedStatus = Arc<RwLock<Status>>;

pub struct Keeper {
    pub cfg: Config,
    pub rpc: Arc<RpcPool>,
    pub db: Db,
    pub chain: Chain,
    pub tx: TxSender,
    pub status: SharedStatus,
    out_of_range_since: Option<u64>,
    last_skip: Option<&'static str>,
}

fn i24(v: I24) -> i32 {
    v.as_i32()
}

/// Mirrors `OracleLibrary.consult`: mean tick over `window`, rounded toward negative infinity.
pub fn twap_tick(cum_old: i64, cum_new: i64, window: u32) -> i32 {
    let delta = cum_new - cum_old;
    let w = window as i64;
    let mut t = delta / w;
    if delta < 0 && delta % w != 0 {
        t -= 1;
    }
    t as i32
}

/// Human-readable revert reason from raw revert data.
pub fn revert_reason(data: &Option<Bytes>) -> String {
    match data {
        Some(d) => match IAutoBaseVault::IAutoBaseVaultErrors::abi_decode(d) {
            Ok(e) => format!("{e:?}"),
            Err(_) => format!("unknown revert 0x{}", alloy::hex::encode(d)),
        },
        None => "revert without data".into(),
    }
}

impl Keeper {
    pub fn new(cfg: Config, rpc: Arc<RpcPool>, db: Db, chain: Chain, tx: TxSender, status: SharedStatus) -> Self {
        Self {
            cfg,
            rpc,
            db,
            chain,
            tx,
            status,
            out_of_range_since: None,
            last_skip: None,
        }
    }

    pub async fn run(mut self) -> anyhow::Result<()> {
        if let Some((id, outcome)) = self.tx.resume().await? {
            self.record_outcome(id, &outcome).await?;
        }
        let closed = self.db.close_interrupted_actions().await?;
        if closed > 0 {
            warn!(closed, "marked actions from a previous run as interrupted");
        }
        loop {
            if let Err(e) = self.tick().await {
                error!(error = %e, "keeper tick failed");
                self.status.write().unwrap_or_else(|e| e.into_inner()).last_error = Some(e.to_string());
            }
            tokio::time::sleep(self.cfg.poll_interval).await;
        }
    }

    async fn tick(&mut self) -> anyhow::Result<()> {
        let c = self.chain.clone();
        let rpc = &self.rpc;
        let p = rpc.call(c.vault, &IAutoBaseVault::paramsCall {}, None, None).await?;
        let lower = i24(rpc.call(c.vault, &IAutoBaseVault::tickLowerCall {}, None, None).await?);
        let upper = i24(rpc.call(c.vault, &IAutoBaseVault::tickUpperCall {}, None, None).await?);
        let last_rebalance: u64 = rpc
            .call(c.vault, &IAutoBaseVault::lastRebalanceCall {}, None, None)
            .await?
            .to();
        let paused = rpc.call(c.vault, &IAutoBaseVault::pausedCall {}, None, None).await?;
        let liquidity = rpc
            .call(c.vault, &IAutoBaseVault::positionLiquidityCall {}, None, None)
            .await?;
        let slot0 = rpc.call(c.pool, &IUniswapV3Pool::slot0Call {}, None, None).await?;
        let tick = i24(slot0.tick);
        let window = p.twapWindow;
        let obs = rpc
            .call(
                c.pool,
                &IUniswapV3Pool::observeCall {
                    secondsAgos: vec![window, 0],
                },
                None,
                None,
            )
            .await?;
        let twap = twap_tick(obs.tickCumulatives[0].as_i64(), obs.tickCumulatives[1].as_i64(), window);
        let idle0 = rpc
            .call(c.token0, &IERC20::balanceOfCall { account: c.vault }, None, None)
            .await?;
        let idle1 = rpc
            .call(c.token1, &IERC20::balanceOfCall { account: c.vault }, None, None)
            .await?;
        let price = strategy::price_from_sqrt_x96(f64::from(slot0.sqrtPriceX96));
        let idle_value = f64::from(idle0) * price + f64::from(idle1);
        let block = rpc
            .read(|pr| async move { pr.get_block_by_number(BlockNumberOrTag::Latest).await })
            .await?
            .ok_or_else(|| anyhow::anyhow!("no latest block"))?;
        let now = block.header.timestamp;
        let base_fee_gwei = block.header.base_fee_per_gas.unwrap_or(0) as f64 / 1e9;

        let has_position = liquidity != 0;
        let in_range = has_position && tick >= lower && tick < upper;
        self.out_of_range_since = match (has_position && !in_range, self.out_of_range_since) {
            (true, None) => Some(now),
            (true, s) => s,
            (false, _) => None,
        };

        let since = now as i64 - self.cfg.vol_lookback_hours as i64 * 3600;
        let samples = self.db.price_samples_since(since).await?;
        let sigma = strategy::realized_vol_daily(&samples);
        let min_w = i24(p.minHalfWidthTicks);
        let max_w = i24(p.maxHalfWidthTicks);
        let width = strategy::choose_half_width(sigma, self.cfg.target_days_in_range, min_w, max_w, c.tick_spacing);

        let input = DecisionInput {
            paused,
            has_position,
            tick,
            twap_tick: twap,
            max_twap_deviation: i24(p.maxTwapDeviationTicks),
            tick_lower: lower,
            tick_upper: upper,
            recenter_threshold_bps: p.recenterThresholdBps,
            now,
            last_rebalance,
            min_rebalance_interval: p.minRebalanceInterval as u64,
            idle_value,
            compound_min_value: self.cfg.compound_min_value,
            base_fee_gwei,
            max_base_fee_gwei: self.cfg.max_base_fee_gwei,
            out_of_range_secs: self.out_of_range_since.map_or(0, |s| now.saturating_sub(s)),
            max_out_of_range_secs: self.cfg.max_out_of_range.as_secs(),
        };
        let decision = strategy::decide(&input);

        let balance_eth = self
            .tx
            .keeper_balance_wei()
            .await
            .map(|b| b as f64 / 1e18)
            .unwrap_or(-1.0);
        let low = balance_eth >= 0.0 && balance_eth < self.cfg.min_keeper_balance_eth;
        if low {
            warn!(balance_eth, "keeper ETH balance is low");
        }
        let half = ((upper - lower) / 2).max(1) as i64;
        let dist = ((2 * tick as i64 - lower as i64 - upper as i64).abs() * 10_000) / (2 * half);
        {
            let mut s = self.status.write().unwrap_or_else(|e| e.into_inner());
            *s = Status {
                updated_at: now_secs(),
                block_time: now,
                keeper: Some(c.keeper),
                keeper_balance_eth: balance_eth,
                keeper_balance_low: low,
                paused,
                tick,
                twap_tick: twap,
                tick_lower: lower,
                tick_upper: upper,
                in_range,
                position_liquidity: liquidity.to_string(),
                idle0: idle0.to_string(),
                idle1: idle1.to_string(),
                idle_value1: idle_value,
                last_rebalance,
                base_fee_gwei,
                sigma_daily: sigma,
                chosen_half_width: width,
                min_half_width: min_w,
                max_half_width: max_w,
                trigger_distance_bps: if has_position { dist } else { 0 },
                recenter_threshold_bps: p.recenterThresholdBps,
                decision: Some(decision.clone()),
                last_tx: s.last_tx.clone(),
                last_error: None,
            };
        }

        match decision {
            Decision::Skip(reason) => {
                // Log skips only when the reason changes, so the table stays readable.
                if self.last_skip != Some(reason) {
                    self.db
                        .insert_action(now as i64, "skip".into(), Some(reason.into()), None, "skipped")
                        .await?;
                    self.last_skip = Some(reason);
                }
                Ok(())
            }
            Decision::Recenter | Decision::Compound => {
                self.last_skip = None;
                let name = if decision == Decision::Recenter {
                    "recenter"
                } else {
                    "compound"
                };
                self.execute(name, width, now).await
            }
        }
    }

    async fn execute(&mut self, name: &'static str, width: i32, block_time: u64) -> anyhow::Result<()> {
        let action = self
            .db
            .insert_action(block_time as i64, name.into(), None, Some(width), "simulating")
            .await?;
        // Every exit path must close the action row; an error would otherwise leave it "simulating" forever.
        // (If a tx was already broadcast, `pending_tx` keeps it and `resume` fixes the status later.)
        if let Err(e) = self.execute_action(action, name, width, block_time).await {
            self.db
                .update_action(action, "failed", None, None, None, Some(e.to_string()))
                .await?;
            return Err(e);
        }
        Ok(())
    }

    async fn execute_action(
        &mut self,
        action: i64,
        name: &'static str,
        width: i32,
        block_time: u64,
    ) -> anyhow::Result<()> {
        let c = &self.chain;
        let deadline = block_time + self.cfg.tx_deadline_secs;
        let width_i24 = I24::try_from(width)?;

        // 1. Simulate as the keeper to learn the liquidity this call would add.
        let sim = IAutoBaseVault::rebalanceCall {
            halfWidthTicks: width_i24,
            minLiquidity: 0,
            deadline: U256::from(deadline),
        };
        let added = match self.rpc.call(c.vault, &sim, Some(c.keeper), None).await {
            Ok(a) => a,
            Err(RpcError::Reverted(data)) => {
                let reason = revert_reason(&data);
                warn!(%reason, "rebalance simulation reverted");
                self.db
                    .update_action(action, "simulation_reverted", None, None, None, Some(reason))
                    .await?;
                return Ok(());
            }
            Err(e) => return Err(e.into()),
        };

        // 2. Real call with a 1% liquidity floor and a gas estimate with headroom.
        let call = IAutoBaseVault::rebalanceCall {
            halfWidthTicks: width_i24,
            minLiquidity: added - added / 100,
            deadline: U256::from(deadline),
        };
        let input = Bytes::from(call.abi_encode());
        let req = TransactionRequest::default()
            .from(c.keeper)
            .to(c.vault)
            .input(input.clone().into());
        let gas = match self
            .rpc
            .read(|p| {
                let r = req.clone();
                async move { p.estimate_gas(r).await }
            })
            .await
        {
            Ok(g) => g * 13 / 10,
            Err(RpcError::Reverted(data)) => {
                let reason = revert_reason(&data);
                self.db
                    .update_action(action, "simulation_reverted", None, None, None, Some(reason))
                    .await?;
                return Ok(());
            }
            Err(e) => return Err(e.into()),
        };

        info!(name, width, added, gas, "sending rebalance");
        self.db.update_action(action, "sent", None, None, None, None).await?;
        let outcome = self.tx.send(c.vault, input, gas, deadline, action).await?;
        self.record_outcome(action, &outcome).await
    }

    async fn record_outcome(&self, action: i64, outcome: &TxOutcome) -> anyhow::Result<()> {
        match outcome {
            TxOutcome::Mined {
                hash,
                success,
                gas_used,
                cost_wei,
            } => {
                let status = if *success { "success" } else { "reverted" };
                info!(%hash, status, gas_used, "rebalance mined");
                self.db
                    .update_action(
                        action,
                        status,
                        Some(hash.to_string()),
                        Some(*gas_used),
                        Some(cost_wei.to_string()),
                        None,
                    )
                    .await?;
                self.status.write().unwrap_or_else(|e| e.into_inner()).last_tx = Some(hash.to_string());
            }
            TxOutcome::Expired { last_hash } => {
                warn!(%last_hash, "rebalance tx expired before inclusion");
                self.db
                    .update_action(action, "expired", Some(last_hash.to_string()), None, None, None)
                    .await?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn twap_rounds_toward_negative_infinity() {
        assert_eq!(twap_tick(0, 600, 600), 1);
        assert_eq!(twap_tick(0, -600, 600), -1);
        assert_eq!(twap_tick(0, -601, 600), -2); // floor, like OracleLibrary.consult
        assert_eq!(twap_tick(0, 599, 600), 0);
    }

    #[test]
    fn decodes_vault_errors() {
        use alloy::sol_types::SolError;
        let data = Some(Bytes::from(IAutoBaseVault::Cooldown::SELECTOR.to_vec()));
        assert!(revert_reason(&data).contains("Cooldown"));
        assert!(revert_reason(&Some(Bytes::from(vec![1, 2, 3, 4]))).starts_with("unknown revert"));
        assert_eq!(revert_reason(&None), "revert without data");
    }
}
