//! Transaction sending: local signing, private-relay first, public rebroadcast, same-nonce fee bumps,
//! and crash-safe tracking of the single in-flight transaction.

use std::{sync::Arc, time::Duration};

use alloy::{
    consensus::TxEnvelope,
    eips::{BlockNumberOrTag, eip2718::Encodable2718},
    network::{EthereumWallet, TransactionBuilder},
    primitives::{Address, B256, Bytes},
    providers::Provider,
    rpc::types::{TransactionReceipt, TransactionRequest},
    signers::local::PrivateKeySigner,
};
use reqwest::Url;
use tracing::{info, warn};

use crate::{
    db::{Db, PendingTx},
    rpc::{Endpoint, RpcError, RpcPool},
};

const GWEI: f64 = 1e9;
/// Same-nonce replacements need >= 10% higher fees; use 15% to be safe.
const BUMP_NUM: u128 = 115;
const BUMP_DEN: u128 = 100;
const MAX_BUMPS: usize = 4;

#[derive(Debug)]
pub enum TxOutcome {
    Mined {
        hash: B256,
        success: bool,
        gas_used: u64,
        cost_wei: u128,
    },
    /// Never mined before the on-chain deadline (it would revert if mined later).
    Expired { last_hash: B256 },
}

pub struct TxSender {
    wallet: EthereumWallet,
    pub address: Address,
    chain_id: u64,
    pool: Arc<RpcPool>,
    relays: Vec<Endpoint>,
    db: Db,
    max_fee_wei: u128,
    priority_fee_wei: u128,
    wait_blocks: u64,
}

impl TxSender {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        signer: PrivateKeySigner,
        chain_id: u64,
        pool: Arc<RpcPool>,
        relays: &[Url],
        timeout: Duration,
        db: Db,
        max_fee_gwei: f64,
        priority_fee_gwei: f64,
        wait_blocks: u64,
    ) -> anyhow::Result<Self> {
        let address = signer.address();
        let relays = relays
            .iter()
            .map(|u| Endpoint::new(u.clone(), timeout))
            .collect::<anyhow::Result<_>>()?;
        Ok(Self {
            wallet: EthereumWallet::from(signer),
            address,
            chain_id,
            pool,
            relays,
            db,
            max_fee_wei: (max_fee_gwei * GWEI) as u128,
            priority_fee_wei: (priority_fee_gwei * GWEI) as u128,
            wait_blocks,
        })
    }

    /// Mined-transaction count (`latest`), max across endpoints. Using `latest` instead of `pending` means
    /// a stuck transaction from an earlier run gets replaced instead of queued behind.
    async fn nonce(&self) -> Result<u64, RpcError> {
        let mut best = None;
        for ep in self.pool.endpoints().iter().take(3) {
            if let Ok(n) = ep.provider.get_transaction_count(self.address).latest().await {
                best = Some(best.map_or(n, |b: u64| b.max(n)));
            }
        }
        match best {
            Some(n) => Ok(n),
            None => {
                self.pool
                    .read(|p| async move { p.get_transaction_count(self.address).latest().await })
                    .await
            }
        }
    }

    pub async fn base_fee_wei(&self) -> Result<u128, RpcError> {
        let block = self
            .pool
            .read(|p| async move { p.get_block_by_number(BlockNumberOrTag::Latest).await })
            .await?;
        Ok(block.and_then(|b| b.header.base_fee_per_gas).unwrap_or(0) as u128)
    }

    pub async fn keeper_balance_wei(&self) -> Result<u128, RpcError> {
        let b = self
            .pool
            .read(|p| async move { p.get_balance(self.address).await })
            .await?;
        Ok(b.to::<u128>())
    }

    async fn sign(
        &self,
        to: Address,
        input: &Bytes,
        nonce: u64,
        gas: u64,
        max_fee: u128,
        prio: u128,
    ) -> anyhow::Result<(B256, Bytes)> {
        let tx = TransactionRequest::default()
            .with_from(self.address)
            .with_to(to)
            .with_input(input.clone())
            .with_nonce(nonce)
            .with_chain_id(self.chain_id)
            .with_gas_limit(gas)
            .with_max_fee_per_gas(max_fee)
            .with_max_priority_fee_per_gas(prio);
        let env: TxEnvelope = tx.build(&self.wallet).await?;
        Ok((*env.tx_hash(), Bytes::from(env.encoded_2718())))
    }

    /// Private relays first; public broadcast if none configured or none accepted.
    async fn broadcast(&self, raw: &Bytes, public_too: bool) -> usize {
        let mut accepted = 0;
        for relay in &self.relays {
            match relay.provider.send_raw_transaction(raw).await {
                Ok(_) => accepted += 1,
                Err(e) => warn!(relay = %relay.name, error = %e, "private relay rejected tx"),
            }
        }
        if accepted == 0 || public_too {
            accepted += self.pool.broadcast_raw(raw).await;
        }
        accepted
    }

    async fn receipt(&self, hash: B256) -> Option<TransactionReceipt> {
        self.pool
            .read(|p| async move { p.get_transaction_receipt(hash).await })
            .await
            .ok()
            .flatten()
    }

    /// Waits up to `blocks` blocks for any of `hashes` to be mined.
    async fn wait_any(&self, hashes: &[B256], blocks: u64) -> Option<TransactionReceipt> {
        let polls = (blocks * 12) / 4 + 1;
        for _ in 0..polls {
            for h in hashes {
                if let Some(r) = self.receipt(*h).await {
                    return Some(r);
                }
            }
            tokio::time::sleep(Duration::from_secs(4)).await;
        }
        None
    }

    fn outcome(r: &TransactionReceipt) -> TxOutcome {
        TxOutcome::Mined {
            hash: r.transaction_hash,
            success: r.status(),
            gas_used: r.gas_used,
            cost_wei: r.gas_used as u128 * r.effective_gas_price,
        }
    }

    /// Sends `input` to `to` and follows it to inclusion or expiry. `deadline` is the on-chain deadline
    /// encoded in the call; after it passes the tx can only revert, so we stop chasing it.
    pub async fn send(
        &self,
        to: Address,
        input: Bytes,
        gas_limit: u64,
        deadline: u64,
        action_id: i64,
    ) -> anyhow::Result<TxOutcome> {
        let nonce = self.nonce().await?;
        let base = self.base_fee_wei().await?;
        let mut prio = self.priority_fee_wei.min(self.max_fee_wei);
        let mut max_fee = (base * 2 + prio).min(self.max_fee_wei);
        anyhow::ensure!(
            max_fee > base,
            "base fee {} gwei is above MAX_FEE_GWEI",
            base as f64 / GWEI
        );

        let mut hashes = Vec::new();
        for attempt in 0..=MAX_BUMPS {
            let (hash, raw) = self.sign(to, &input, nonce, gas_limit, max_fee, prio).await?;
            hashes.push(hash);
            let head = self.pool.best_head();
            self.db
                .save_pending(PendingTx {
                    action_id,
                    tx_hash: hash.to_string(),
                    nonce,
                    raw: raw.to_string(),
                    sent_block: head,
                    deadline,
                })
                .await?;
            let accepted = self.broadcast(&raw, false).await;
            info!(%hash, nonce, attempt, accepted, max_fee_gwei = max_fee as f64 / GWEI, "tx sent");

            if let Some(r) = self.wait_any(&hashes, self.wait_blocks).await {
                self.db.clear_pending().await?;
                return Ok(Self::outcome(&r));
            }
            // Not included: push it to public nodes too, then wait once more before bumping.
            warn!(%hash, "tx not included yet, rebroadcasting publicly");
            self.broadcast(&raw, true).await;
            if let Some(r) = self.wait_any(&hashes, self.wait_blocks).await {
                self.db.clear_pending().await?;
                return Ok(Self::outcome(&r));
            }
            if now_secs() > deadline {
                break;
            }
            let next_fee = (max_fee * BUMP_NUM / BUMP_DEN).min(self.max_fee_wei);
            if next_fee <= max_fee {
                warn!("fee cap reached; waiting for inclusion without further bumps");
                continue;
            }
            max_fee = next_fee;
            prio = (prio * BUMP_NUM / BUMP_DEN).max(prio + 1).min(max_fee);
        }

        // Final check: a previous attempt may have landed in the meantime.
        if let Some(r) = self.wait_any(&hashes, 1).await {
            self.db.clear_pending().await?;
            return Ok(Self::outcome(&r));
        }
        self.db.clear_pending().await?;
        Ok(TxOutcome::Expired {
            last_hash: *hashes.last().expect("at least one attempt"),
        })
    }

    /// On startup: finish tracking a tx from a previous run. Returns its action id and outcome.
    pub async fn resume(&self) -> anyhow::Result<Option<(i64, TxOutcome)>> {
        let Some(p) = self.db.load_pending().await? else {
            return Ok(None);
        };
        let hash: B256 = p.tx_hash.parse()?;
        info!(%hash, "resuming pending tx from previous run");
        if now_secs() <= p.deadline {
            let raw: Bytes = p.raw.parse()?;
            self.broadcast(&raw, true).await;
        }
        let outcome = match self.wait_any(&[hash], self.wait_blocks).await {
            Some(r) => Self::outcome(&r),
            None => TxOutcome::Expired { last_hash: hash },
        };
        self.db.clear_pending().await?;
        Ok(Some((p.action_id, outcome)))
    }
}

pub fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
