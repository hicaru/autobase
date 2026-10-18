mod abi;
mod config;
mod db;
mod fees;
mod indexer;
mod keeper;
mod rpc;
mod server;
mod strategy;
mod tx;

use std::{
    future::Future,
    sync::{Arc, RwLock},
    time::Duration,
};

use alloy::{primitives::Address, providers::Provider};
use clap::Parser;
use tracing::{error, info, warn};

use crate::{
    abi::IAutoBaseVault,
    config::{Cli, Config, PRIVATE_KEY_ENV},
    db::Db,
    indexer::Indexer,
    keeper::{Chain, Keeper, SharedStatus, Status},
    rpc::RpcPool,
    server::AppState,
    tx::TxSender,
};

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    // Drop the key from the environment while still single-threaded: nothing spawned later
    // (or a crash dump of /proc/<pid>/environ after this point) can read it from there.
    // SAFETY: no other threads exist yet.
    unsafe { std::env::remove_var(PRIVATE_KEY_ENV) };
    let (cfg, secrets) = Config::from_cli(cli)?;

    init_tracing(cfg.log_json);
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?
        .block_on(run(cfg, secrets))
}

fn init_tracing(json: bool) {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info,autobase_bot=info"));
    let b = tracing_subscriber::fmt().with_env_filter(filter).with_target(false);
    if json { b.json().init() } else { b.init() }
}

async fn run(cfg: Config, secrets: config::Secrets) -> anyhow::Result<()> {
    let db = Db::open(&cfg.db_path)?;
    let rpc = Arc::new(RpcPool::connect(&cfg.read_rpcs, cfg.chain_id, cfg.rpc_timeout, cfg.max_head_lag).await?);
    rpc.check_health().await;

    let chain = resolve_chain(&rpc, cfg.vault).await?;
    let keeper_addr = secrets.signer.address();
    anyhow::ensure!(
        chain.keeper == keeper_addr,
        "vault keeper is {}, but KEEPER_PRIVATE_KEY is {} — refusing to start",
        chain.keeper,
        keeper_addr
    );
    info!(vault = %chain.vault, pool = %chain.pool, keeper = %keeper_addr, "vault resolved");

    let status: SharedStatus = Arc::new(RwLock::new(Status::default()));
    let tx = TxSender::new(
        secrets.signer,
        cfg.chain_id,
        rpc.clone(),
        &cfg.private_tx_rpcs,
        cfg.rpc_timeout,
        db.clone(),
        cfg.max_fee_gwei,
        cfg.priority_fee_gwei,
        cfg.tx_wait_blocks,
    )?;
    let app = AppState::new(db.clone(), rpc.clone(), status.clone(), secrets.api_key.as_bytes(), 10);
    drop(secrets.api_key);

    let indexer = Arc::new(Indexer {
        cfg: cfg.clone(),
        rpc: rpc.clone(),
        db: db.clone(),
        chain: chain.clone(),
    });
    // The keeper owns the signer, so it is not restartable from scratch: it runs in its own supervised loop
    // that never returns (errors inside a tick are logged and retried on the next poll).
    let keeper = Keeper::new(cfg.clone(), rpc.clone(), db.clone(), chain, tx, status);

    {
        let r = rpc.clone();
        supervise("rpc-health", move || r.clone().health_loop(Duration::from_secs(12)));
    }
    {
        let i = indexer.clone();
        supervise("events", move || i.clone().events_loop());
    }
    {
        let i = indexer.clone();
        supervise("prices", move || i.clone().prices_loop());
    }
    {
        let i = indexer.clone();
        supervise("snapshots", move || i.clone().snapshots_loop());
    }
    {
        let bind = cfg.api_bind;
        supervise("api", move || server::serve(app.clone(), bind));
    }
    let keeper_task = tokio::spawn(keeper.run());
    info!(bind = %cfg.api_bind, "autobase-bot running");

    tokio::select! {
        _ = shutdown_signal() => info!("shutdown requested"),
        r = keeper_task => match r {
            Ok(Ok(())) => warn!("keeper loop exited"),
            Ok(Err(e)) => error!(error = %e, "keeper loop failed"),
            // A panic in the keeper is fatal on purpose: let systemd restart the process with clean state.
            Err(e) => error!(error = %e, "keeper loop panicked"),
        },
    }
    Ok(())
}

async fn resolve_chain(rpc: &RpcPool, vault: Address) -> anyhow::Result<Chain> {
    let code = rpc.read(|p| async move { p.get_code_at(vault).await }).await?;
    anyhow::ensure!(!code.is_empty(), "no contract at VAULT_ADDRESS {vault}");
    Ok(Chain {
        vault,
        pool: rpc.call(vault, &IAutoBaseVault::poolCall {}, None, None).await?,
        token0: rpc.call(vault, &IAutoBaseVault::token0Call {}, None, None).await?,
        token1: rpc.call(vault, &IAutoBaseVault::token1Call {}, None, None).await?,
        tick_spacing: rpc
            .call(vault, &IAutoBaseVault::tickSpacingCall {}, None, None)
            .await?
            .as_i32(),
        keeper: rpc.call(vault, &IAutoBaseVault::keeperCall {}, None, None).await?,
    })
}

/// Runs `make()` forever: restarts after errors or panics with exponential backoff (1s → 60s),
/// so one failing component never takes the process down.
fn supervise<F, Fut>(name: &'static str, make: F)
where
    F: Fn() -> Fut + Send + 'static,
    Fut: Future<Output = anyhow::Result<()>> + Send + 'static,
{
    tokio::spawn(async move {
        let mut backoff = Duration::from_secs(1);
        loop {
            match tokio::spawn(make()).await {
                Ok(Ok(())) => warn!(task = name, "task exited; restarting"),
                Ok(Err(e)) => error!(task = name, error = %e, ?backoff, "task failed; restarting"),
                Err(e) => error!(task = name, error = %e, ?backoff, "task panicked; restarting"),
            }
            tokio::time::sleep(backoff).await;
            backoff = (backoff * 2).min(Duration::from_secs(60));
        }
    });
}

async fn shutdown_signal() {
    let ctrl_c = tokio::signal::ctrl_c();
    #[cfg(unix)]
    {
        let mut term = match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(s) => s,
            Err(_) => return ctrl_c.await.unwrap_or(()),
        };
        tokio::select! {
            _ = ctrl_c => {},
            _ = term.recv() => {},
        }
    }
    #[cfg(not(unix))]
    ctrl_c.await.unwrap_or(());
}
