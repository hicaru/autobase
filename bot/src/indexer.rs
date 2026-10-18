//! Analytics: vault event tailing (reorg-safe via confirmations), hourly price samples, and periodic
//! snapshots with fee accrual computed from the pool's fee-growth accounting.

use std::{collections::HashMap, sync::Arc, time::Duration};

use alloy::{
    eips::BlockNumberOrTag,
    primitives::{Address, B256, U256, aliases::I24, keccak256},
    providers::Provider,
    rpc::types::{Filter, Log},
    sol_types::SolEvent,
};
use duckdb::ToSql;
use tracing::{debug, info, warn};

use crate::{
    abi::{IAutoBaseVault, IUniswapV3Pool},
    config::Config,
    db::{Db, EventTable, Snapshot},
    fees::{self, FeeGrowth},
    keeper::Chain,
    rpc::RpcPool,
    strategy::price_from_sqrt_x96,
    tx::now_secs,
};

const LOG_CHUNK: u64 = 2_000;
const BLOCKS_PER_HOUR: u64 = 300;
const CURSOR_KEY: &str = "event_cursor";

pub struct Indexer {
    pub cfg: Config,
    pub rpc: Arc<RpcPool>,
    pub db: Db,
    pub chain: Chain,
}

/// Uniswap position key: keccak256(abi.encodePacked(owner, int24 lower, int24 upper)).
pub fn position_key(owner: Address, lower: i32, upper: i32) -> B256 {
    let mut buf = Vec::with_capacity(26);
    buf.extend_from_slice(owner.as_slice());
    buf.extend_from_slice(&lower.to_be_bytes()[1..]);
    buf.extend_from_slice(&upper.to_be_bytes()[1..]);
    keccak256(buf)
}

fn to_f64(v: U256) -> f64 {
    f64::from(v)
}

fn b<T: ToSql + Send + 'static>(v: T) -> Box<dyn ToSql + Send> {
    Box::new(v)
}

impl Indexer {
    async fn head(&self) -> anyhow::Result<u64> {
        let best = self.rpc.best_head();
        if best > 0 {
            return Ok(best);
        }
        Ok(self.rpc.read(|p| async move { p.get_block_number().await }).await?)
    }

    async fn block_ts(&self, block: u64, cache: &mut HashMap<u64, u64>) -> anyhow::Result<u64> {
        if let Some(t) = cache.get(&block) {
            return Ok(*t);
        }
        let blk = self
            .rpc
            .read(|p| async move { p.get_block_by_number(BlockNumberOrTag::Number(block)).await })
            .await?
            .ok_or_else(|| anyhow::anyhow!("block {block} not found"))?;
        cache.insert(block, blk.header.timestamp);
        Ok(blk.header.timestamp)
    }

    /// (price of token0 in token1 base units, tick) at `block` (latest when `None`).
    async fn price_at(&self, block: Option<u64>) -> anyhow::Result<(f64, i32)> {
        let s = self
            .rpc
            .call(self.chain.pool, &IUniswapV3Pool::slot0Call {}, None, block)
            .await?;
        Ok((price_from_sqrt_x96(f64::from(s.sqrtPriceX96)), s.tick.as_i32()))
    }

    // ------------------------------------------------------------------ events

    pub async fn events_loop(self: Arc<Self>) -> anyhow::Result<()> {
        let mut cursor = match self.db.kv_get(CURSOR_KEY).await? {
            Some(c) => c.parse()?,
            None => match self.cfg.vault_deploy_block {
                Some(b) => b,
                None => self.head().await?.saturating_sub(self.cfg.confirmations),
            },
        };
        loop {
            let safe = self.head().await?.saturating_sub(self.cfg.confirmations);
            while cursor <= safe {
                let to = (cursor + LOG_CHUNK - 1).min(safe);
                let filter = Filter::new().address(self.chain.vault).from_block(cursor).to_block(to);
                let logs = self
                    .rpc
                    .read(|p| {
                        let f = filter.clone();
                        async move { p.get_logs(&f).await }
                    })
                    .await?;
                let mut ts_cache = HashMap::new();
                for log in &logs {
                    if let Err(e) = self.store_log(log, &mut ts_cache).await {
                        warn!(error = %e, "failed to store log");
                        return Err(e);
                    }
                }
                debug!(from = cursor, to, logs = logs.len(), "indexed");
                cursor = to + 1;
                self.db.kv_set(CURSOR_KEY, cursor.to_string()).await?;
            }
            tokio::time::sleep(Duration::from_secs(30)).await;
        }
    }

    async fn store_log(&self, log: &Log, ts_cache: &mut HashMap<u64, u64>) -> anyhow::Result<()> {
        let Some(topic0) = log.topic0().copied() else {
            return Ok(());
        };
        let block = log.block_number.unwrap_or_default();
        let idx = log.log_index.unwrap_or_default() as i32;
        let tx = log.transaction_hash.map(|h| h.to_string()).unwrap_or_default();
        let ts = self.block_ts(block, ts_cache).await? as i64;
        let head = || -> Vec<Box<dyn ToSql + Send>> { vec![b(block as i64), b(idx), b(tx.clone()), b(ts)] };
        let data = log.data();

        if topic0 == IAutoBaseVault::Deposited::SIGNATURE_HASH {
            let e = IAutoBaseVault::Deposited::decode_log_data(data)?;
            let mut v = head();
            v.extend([
                b(e.user.to_string()),
                b(e.amount0.to_string()),
                b(e.amount1.to_string()),
                b(e.shares.to_string()),
            ]);
            self.db.insert_event(EventTable::Deposits, v).await?;
        } else if topic0 == IAutoBaseVault::Withdrawn::SIGNATURE_HASH {
            let e = IAutoBaseVault::Withdrawn::decode_log_data(data)?;
            let mut v = head();
            v.extend([
                b(e.user.to_string()),
                b(e.shares.to_string()),
                b(e.amount0.to_string()),
                b(e.amount1.to_string()),
            ]);
            self.db.insert_event(EventTable::Withdrawals, v).await?;
        } else if topic0 == IAutoBaseVault::Rebalanced::SIGNATURE_HASH {
            let e = IAutoBaseVault::Rebalanced::decode_log_data(data)?;
            // Value fees at the price of that block (archive read); fall back to the current price.
            let price = match self.price_at(Some(block)).await {
                Ok((p, _)) => p,
                Err(_) => self.price_at(None).await?.0,
            };
            let fees_value = to_f64(e.fees0) * price + to_f64(e.fees1);
            let mut v = head();
            v.extend([
                b(e.oldLower.as_i32()),
                b(e.oldUpper.as_i32()),
                b(e.newLower.as_i32()),
                b(e.newUpper.as_i32()),
                b(e.halfWidthTicks.as_i32()),
                b(e.liquidityAdded.to_string()),
                b(e.fees0.to_string()),
                b(e.fees1.to_string()),
                b(fees_value),
            ]);
            self.db.insert_event(EventTable::Rebalances, v).await?;
        } else if topic0 == IAutoBaseVault::Swapped::SIGNATURE_HASH {
            let e = IAutoBaseVault::Swapped::decode_log_data(data)?;
            let mut v = head();
            v.extend([b(e.zeroForOne), b(e.amountIn.to_string()), b(e.amountOut.to_string())]);
            self.db.insert_event(EventTable::Swaps, v).await?;
        } else {
            let kind = if topic0 == IAutoBaseVault::PositionExited::SIGNATURE_HASH {
                "PositionExited"
            } else if topic0 == IAutoBaseVault::ParamsSet::SIGNATURE_HASH {
                "ParamsSet"
            } else if topic0 == IAutoBaseVault::KeeperSet::SIGNATURE_HASH {
                "KeeperSet"
            } else {
                "Other"
            };
            let mut v = head();
            v.extend([b(kind.to_string()), b(alloy::hex::encode_prefixed(data.data.as_ref()))]);
            self.db.insert_event(EventTable::Admin, v).await?;
            info!(kind, block, "admin event indexed");
        }
        Ok(())
    }

    // ------------------------------------------------------------------ prices

    pub async fn prices_loop(self: Arc<Self>) -> anyhow::Result<()> {
        self.backfill_prices().await;
        loop {
            let head = self.head().await?;
            let (_, tick) = self.price_at(None).await?;
            self.db.insert_price_sample(now_secs() as i64, head, tick).await?;
            tokio::time::sleep(Duration::from_secs(3600)).await;
        }
    }

    /// Fills missing hourly samples from archive state. Best effort: non-archive nodes just fail.
    async fn backfill_prices(&self) {
        let hours = self.cfg.vol_lookback_hours;
        let since = now_secs() as i64 - hours as i64 * 3600;
        let have = self.db.price_samples_since(since).await.map(|s| s.len()).unwrap_or(0) as u64;
        if have * 10 >= hours * 8 {
            return;
        }
        let Ok(head) = self.head().await else { return };
        info!(hours, have, "backfilling price samples from archive");
        let mut cache = HashMap::new();
        let mut ok = 0;
        for h in 1..=hours {
            let block = head.saturating_sub(h * BLOCKS_PER_HOUR);
            let (Ok((_, tick)), Ok(ts)) = (self.price_at(Some(block)).await, self.block_ts(block, &mut cache).await)
            else {
                continue;
            };
            if self.db.insert_price_sample(ts as i64, block, tick).await.is_ok() {
                ok += 1;
            }
        }
        info!(ok, "price backfill done");
    }

    // ------------------------------------------------------------------ snapshots

    pub async fn snapshots_loop(self: Arc<Self>) -> anyhow::Result<()> {
        loop {
            if let Err(e) = self.snapshot().await {
                warn!(error = %e, "snapshot failed");
            }
            tokio::time::sleep(self.cfg.snapshot_interval).await;
        }
    }

    async fn snapshot(&self) -> anyhow::Result<()> {
        let (c, rpc) = (&self.chain, &self.rpc);
        let block = self.head().await?;
        let at = Some(block);
        let s0 = rpc.call(c.pool, &IUniswapV3Pool::slot0Call {}, None, at).await?;
        let tick = s0.tick.as_i32();
        let price = price_from_sqrt_x96(f64::from(s0.sqrtPriceX96));
        let lower = rpc
            .call(c.vault, &IAutoBaseVault::tickLowerCall {}, None, at)
            .await?
            .as_i32();
        let upper = rpc
            .call(c.vault, &IAutoBaseVault::tickUpperCall {}, None, at)
            .await?
            .as_i32();
        let liquidity = rpc
            .call(c.vault, &IAutoBaseVault::positionLiquidityCall {}, None, at)
            .await?;
        let totals = rpc
            .call(c.vault, &IAutoBaseVault::totalAmountsCall {}, None, at)
            .await?;
        let supply = rpc.call(c.vault, &IAutoBaseVault::totalSupplyCall {}, None, at).await?;

        let (mut pend0, mut pend1, mut fgi0, mut fgi1) = (U256::ZERO, U256::ZERO, U256::ZERO, U256::ZERO);
        if liquidity != 0 {
            let key = position_key(c.vault, lower, upper);
            let pos = rpc
                .call(c.pool, &IUniswapV3Pool::positionsCall { key }, None, at)
                .await?;
            let lo = rpc
                .call(
                    c.pool,
                    &IUniswapV3Pool::ticksCall {
                        tick: I24::try_from(lower)?,
                    },
                    None,
                    at,
                )
                .await?;
            let up = rpc
                .call(
                    c.pool,
                    &IUniswapV3Pool::ticksCall {
                        tick: I24::try_from(upper)?,
                    },
                    None,
                    at,
                )
                .await?;
            let g0 = rpc
                .call(c.pool, &IUniswapV3Pool::feeGrowthGlobal0X128Call {}, None, at)
                .await?;
            let g1 = rpc
                .call(c.pool, &IUniswapV3Pool::feeGrowthGlobal1X128Call {}, None, at)
                .await?;
            fgi0 = fees::fee_growth_inside(
                tick,
                lower,
                upper,
                FeeGrowth {
                    global: g0,
                    outside_lower: lo.feeGrowthOutside0X128,
                    outside_upper: up.feeGrowthOutside0X128,
                },
            );
            fgi1 = fees::fee_growth_inside(
                tick,
                lower,
                upper,
                FeeGrowth {
                    global: g1,
                    outside_lower: lo.feeGrowthOutside1X128,
                    outside_upper: up.feeGrowthOutside1X128,
                },
            );
            pend0 = fees::pending_fees(pos.tokensOwed0, pos.liquidity, fgi0, pos.feeGrowthInside0LastX128);
            pend1 = fees::pending_fees(pos.tokensOwed1, pos.liquidity, fgi1, pos.feeGrowthInside1LastX128);
        }

        // Fees earned since the previous snapshot, if the range did not move in between.
        let (mut acc0, mut acc1) = (U256::ZERO, U256::ZERO);
        if let Some((pl, pu, pliq, pf0, pf1)) = self.db.last_snapshot_growth().await?
            && pl == lower
            && pu == upper
            && liquidity != 0
        {
            let prev_liq: u128 = pliq.parse().unwrap_or(0);
            acc0 = fees::fees_for(prev_liq, fgi0, pf0.parse().unwrap_or(fgi0));
            acc1 = fees::fees_for(prev_liq, fgi1, pf1.parse().unwrap_or(fgi1));
        }

        let tvl = to_f64(totals.total0) * price + to_f64(totals.total1);
        let supply_f = to_f64(supply);
        self.db
            .insert_snapshot(Snapshot {
                ts: now_secs() as i64,
                block,
                tick,
                tick_lower: lower,
                tick_upper: upper,
                in_range: liquidity != 0 && tick >= lower && tick < upper,
                liquidity: liquidity.to_string(),
                total0: totals.total0.to_string(),
                total1: totals.total1.to_string(),
                tvl_value1: tvl,
                pending_fees0: pend0.to_string(),
                pending_fees1: pend1.to_string(),
                pending_fees_value1: to_f64(pend0) * price + to_f64(pend1),
                fee_growth_inside0: fgi0.to_string(),
                fee_growth_inside1: fgi1.to_string(),
                accrued_fees0: acc0.to_string(),
                accrued_fees1: acc1.to_string(),
                accrued_fees_value1: to_f64(acc0) * price + to_f64(acc1),
                total_supply: supply.to_string(),
                share_price: if supply_f > 0.0 { tvl / supply_f } else { 0.0 },
                price,
            })
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn position_key_matches_solidity_encoding() {
        // Reference from foundry, independent of this code:
        // cast keccak $(cast abi-encode --packed "f(address,int24,int24)" 0x…01 -600 600)
        let owner: Address = "0x0000000000000000000000000000000000000001".parse().unwrap();
        let expected: B256 = "0x197deab4fa8929d58a8cbb129980ee9a268336472aa5be512bdb756ef0e6edf1"
            .parse()
            .unwrap();
        assert_eq!(position_key(owner, -600, 600), expected);
    }
}
