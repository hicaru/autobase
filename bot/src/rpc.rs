//! Multi-endpoint JSON-RPC pool: primary first, ordered failover, per-endpoint health, chain-id pinning.
//!
//! Execution reverts are *not* endpoint failures: they are returned immediately instead of being retried
//! on the next node (another node would revert the same way, and retrying would hide the reason).

use std::{
    future::Future,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

use alloy::{
    eips::BlockId,
    primitives::{Address, Bytes},
    providers::{Provider, RootProvider},
    rpc::{client::RpcClient, types::TransactionRequest},
    sol_types::SolCall,
    transports::TransportError,
};
use reqwest::Url;
use serde::Serialize;
use tracing::{debug, info, warn};

/// Outcome of a failed pool request.
#[derive(Debug, thiserror::Error)]
pub enum RpcError {
    /// The call executed and reverted; carries the raw revert data when the node returned it.
    #[error("execution reverted")]
    Reverted(Option<Bytes>),
    /// Every endpoint failed at the transport / node level.
    #[error("all rpc endpoints failed: {0}")]
    AllFailed(String),
    #[error("abi decode: {0}")]
    Decode(String),
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct EndpointStatus {
    pub name: String,
    pub healthy: bool,
    pub head: u64,
    pub latency_ms: u64,
    pub ok: u64,
    pub errors: u64,
    pub last_error: Option<String>,
}

pub struct Endpoint {
    /// Host only: full URLs may embed API keys and must never be logged or served.
    pub name: String,
    pub provider: RootProvider,
    stats: Mutex<EndpointStatus>,
}

impl Endpoint {
    pub fn new(url: Url, timeout: Duration) -> anyhow::Result<Self> {
        let name = url.host_str().unwrap_or("unknown").to_string();
        let client = reqwest::Client::builder()
            .timeout(timeout)
            .connect_timeout(timeout)
            .build()?;
        let rpc = RpcClient::new_http_with_client(client, url);
        let stats = EndpointStatus {
            name: name.clone(),
            healthy: true,
            ..Default::default()
        };
        Ok(Self {
            name,
            provider: RootProvider::new(rpc),
            stats: Mutex::new(stats),
        })
    }

    fn record(&self, started: Instant, result: Result<(), String>) {
        let mut s = self.stats.lock().unwrap_or_else(|e| e.into_inner());
        s.latency_ms = started.elapsed().as_millis() as u64;
        match result {
            Ok(()) => {
                s.ok += 1;
                s.healthy = true;
            }
            Err(e) => {
                s.errors += 1;
                s.healthy = false;
                s.last_error = Some(truncate(&e, 200));
            }
        }
    }

    pub fn status(&self) -> EndpointStatus {
        self.stats.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

/// True when a node returned a JSON-RPC error that means "the EVM reverted" (not a node problem).
fn revert_data(err: &TransportError) -> Option<Option<Bytes>> {
    let resp = err.as_error_resp()?;
    let msg = resp.message.to_ascii_lowercase();
    (resp.code == 3 || msg.contains("revert")).then(|| resp.as_revert_data())
}

fn truncate(s: &str, max: usize) -> String {
    s.chars().take(max).collect()
}

pub struct RpcPool {
    endpoints: Vec<Arc<Endpoint>>,
    best_head: AtomicU64,
    max_head_lag: u64,
}

impl RpcPool {
    /// Builds the pool and keeps only endpoints that answer with `chain_id`. Order is preserved: the first
    /// URL is the primary.
    pub async fn connect(urls: &[Url], chain_id: u64, timeout: Duration, max_head_lag: u64) -> anyhow::Result<Self> {
        let mut endpoints = Vec::new();
        for url in urls {
            let ep = Endpoint::new(url.clone(), timeout)?;
            match ep.provider.get_chain_id().await {
                Ok(id) if id == chain_id => {
                    info!(endpoint = %ep.name, "rpc endpoint ok");
                    endpoints.push(Arc::new(ep));
                }
                Ok(id) => warn!(endpoint = %ep.name, id, "rpc endpoint on wrong chain, dropped"),
                Err(e) => {
                    // Keep it: it may come back. Health loop will mark it.
                    warn!(endpoint = %ep.name, error = %truncate(&e.to_string(), 200), "rpc endpoint unreachable at startup");
                    ep.record(Instant::now(), Err(e.to_string()));
                    endpoints.push(Arc::new(ep));
                }
            }
        }
        anyhow::ensure!(
            endpoints.iter().any(|e| e.status().healthy),
            "no healthy rpc endpoint on chain {chain_id}"
        );
        Ok(Self {
            endpoints,
            best_head: AtomicU64::new(0),
            max_head_lag,
        })
    }

    pub fn endpoints(&self) -> &[Arc<Endpoint>] {
        &self.endpoints
    }

    pub fn best_head(&self) -> u64 {
        self.best_head.load(Ordering::Relaxed)
    }

    pub fn statuses(&self) -> Vec<EndpointStatus> {
        self.endpoints.iter().map(|e| e.status()).collect()
    }

    /// Endpoints in try order: healthy and in sync first (primary-first), then the rest as last resort.
    fn ordered(&self) -> Vec<Arc<Endpoint>> {
        let best = self.best_head();
        let fresh = |e: &Endpoint| {
            let s = e.status();
            s.healthy && (best == 0 || s.head + self.max_head_lag >= best)
        };
        let (mut good, rest): (Vec<_>, Vec<_>) = self.endpoints.iter().cloned().partition(|e| fresh(e));
        good.extend(rest);
        good
    }

    /// Runs `op` against endpoints in order until one succeeds. Reverts short-circuit.
    pub async fn read<T, F, Fut>(&self, op: F) -> Result<T, RpcError>
    where
        F: Fn(RootProvider) -> Fut,
        Fut: Future<Output = Result<T, TransportError>>,
    {
        let mut last = String::from("no endpoints");
        for ep in self.ordered() {
            let started = Instant::now();
            match op(ep.provider.clone()).await {
                Ok(v) => {
                    ep.record(started, Ok(()));
                    return Ok(v);
                }
                Err(e) => {
                    if let Some(data) = revert_data(&e) {
                        ep.record(started, Ok(()));
                        return Err(RpcError::Reverted(data));
                    }
                    debug!(endpoint = %ep.name, error = %e, "rpc request failed, failing over");
                    last = format!("{}: {}", ep.name, truncate(&e.to_string(), 200));
                    ep.record(started, Err(e.to_string()));
                }
            }
        }
        Err(RpcError::AllFailed(last))
    }

    /// `eth_call` of a typed contract call, optionally `from` an address and at a block.
    pub async fn call<C: SolCall>(
        &self,
        to: Address,
        call: &C,
        from: Option<Address>,
        block: Option<u64>,
    ) -> Result<C::Return, RpcError> {
        let input = Bytes::from(call.abi_encode());
        let raw = self
            .read(|p| {
                let mut tx = TransactionRequest::default().to(to).input(input.clone().into());
                if let Some(f) = from {
                    tx = tx.from(f);
                }
                async move {
                    match block {
                        Some(b) => p.call(tx).block(BlockId::number(b)).await,
                        None => p.call(tx).await,
                    }
                }
            })
            .await?;
        C::abi_decode_returns(&raw).map_err(|e| RpcError::Decode(e.to_string()))
    }

    /// Sends a signed raw tx to every endpoint (public broadcast). Returns how many accepted it.
    pub async fn broadcast_raw(&self, raw: &Bytes) -> usize {
        let futs = self.endpoints.iter().map(|ep| {
            let raw = raw.clone();
            async move {
                let started = Instant::now();
                match ep.provider.send_raw_transaction(&raw).await {
                    Ok(_) => {
                        ep.record(started, Ok(()));
                        true
                    }
                    Err(e) => {
                        let msg = e.to_string().to_ascii_lowercase();
                        // "already known" / "nonce too low" after a successful send elsewhere are fine.
                        let benign = msg.contains("already known") || msg.contains("known transaction");
                        if !benign {
                            debug!(endpoint = %ep.name, error = %e, "broadcast rejected");
                        }
                        benign
                    }
                }
            }
        });
        futures::future::join_all(futs)
            .await
            .into_iter()
            .filter(|ok| *ok)
            .count()
    }

    /// One health round: head + latency for every endpoint, then recompute the best head.
    pub async fn check_health(&self) {
        let futs = self.endpoints.iter().map(|ep| async move {
            let started = Instant::now();
            match ep.provider.get_block_number().await {
                Ok(head) => {
                    ep.record(started, Ok(()));
                    ep.stats.lock().unwrap_or_else(|e| e.into_inner()).head = head;
                }
                Err(e) => ep.record(started, Err(e.to_string())),
            }
        });
        futures::future::join_all(futs).await;
        let best = self
            .endpoints
            .iter()
            .map(|e| e.status())
            .filter(|s| s.healthy)
            .map(|s| s.head)
            .max();
        if let Some(b) = best {
            self.best_head.store(b, Ordering::Relaxed);
        }
    }

    pub async fn health_loop(self: Arc<Self>, every: Duration) -> anyhow::Result<()> {
        loop {
            self.check_health().await;
            tokio::time::sleep(every).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{Json, Router, routing::post};
    use serde_json::{Value, json};

    /// Mock JSON-RPC node. `mode`: "ok", "fail" (HTTP 500), "wrongchain", "revert".
    async fn mock(mode: &'static str, head: u64) -> Url {
        let app = Router::new().route(
            "/",
            post(move |Json(req): Json<Value>| async move {
                let id = req["id"].clone();
                let method = req["method"].as_str().unwrap_or_default().to_string();
                if mode == "fail" {
                    return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, Json(json!({}))) ;
                }
                let result = match method.as_str() {
                    "eth_chainId" => json!(if mode == "wrongchain" { "0x5" } else { "0x1" }),
                    "eth_blockNumber" => json!(format!("0x{head:x}")),
                    "eth_call" if mode == "revert" => {
                        return (
                            axum::http::StatusCode::OK,
                            Json(json!({"jsonrpc":"2.0","id":id,"error":{"code":3,"message":"execution reverted","data":"0x5c52a868"}})),
                        );
                    }
                    "eth_call" => json!("0x000000000000000000000000000000000000000000000000000000000000002a"),
                    _ => json!(null),
                };
                (axum::http::StatusCode::OK, Json(json!({"jsonrpc":"2.0","id":id,"result":result})))
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        Url::parse(&format!("http://{addr}/")).unwrap()
    }

    alloy::sol! {
        function answer() external view returns (uint256);
    }

    #[tokio::test]
    async fn drops_wrong_chain_and_fails_over() {
        let bad = mock("fail", 100).await;
        let wrong = mock("wrongchain", 100).await;
        let good = mock("ok", 100).await;
        let pool = RpcPool::connect(&[bad, wrong, good], 1, Duration::from_secs(2), 3)
            .await
            .unwrap();
        // wrong chain dropped; failing primary kept (may recover) but marked unhealthy.
        assert_eq!(pool.endpoints().len(), 2);
        let v = pool.call(Address::ZERO, &answerCall {}, None, None).await.unwrap();
        assert_eq!(v, alloy::primitives::U256::from(42));
    }

    #[tokio::test]
    async fn revert_is_not_retried() {
        let rev = mock("revert", 100).await;
        let good = mock("ok", 100).await;
        let pool = RpcPool::connect(&[rev, good], 1, Duration::from_secs(2), 3)
            .await
            .unwrap();
        match pool.call(Address::ZERO, &answerCall {}, None, None).await {
            Err(RpcError::Reverted(Some(data))) => assert_eq!(data.as_ref(), &[0x5c, 0x52, 0xa8, 0x68]),
            other => panic!("expected revert, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn lagging_primary_is_skipped() {
        let lagging = mock("ok", 90).await;
        let fresh = mock("ok", 100).await;
        let pool = RpcPool::connect(&[lagging, fresh], 1, Duration::from_secs(2), 3)
            .await
            .unwrap();
        pool.check_health().await;
        assert_eq!(pool.best_head(), 100);
        assert_eq!(pool.ordered()[0].status().head, 100);
    }

    #[tokio::test]
    async fn no_healthy_endpoint_is_an_error() {
        let bad = mock("fail", 1).await;
        assert!(RpcPool::connect(&[bad], 1, Duration::from_secs(2), 3).await.is_err());
    }
}
