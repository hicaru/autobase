//! Configuration from environment / CLI flags. Secrets never implement `Debug` and are zeroized.

use std::{net::SocketAddr, path::PathBuf, time::Duration};

use alloy::{primitives::Address, signers::local::PrivateKeySigner};
use clap::Parser;
use reqwest::Url;
use zeroize::Zeroize;

pub const PRIVATE_KEY_ENV: &str = "KEEPER_PRIVATE_KEY";

#[derive(Parser)]
#[command(name = "autobase-bot", about = "Keeper bot for AutoBaseVault")]
pub struct Cli {
    /// Keeper private key (hex). Read from the env only; removed from the process env after startup.
    #[arg(long, env = PRIVATE_KEY_ENV, hide_env_values = true, hide = true)]
    pub private_key: String,

    #[arg(long, env = "VAULT_ADDRESS")]
    pub vault: Address,

    /// Block the vault was deployed at (indexer start). Defaults to the current head on first run.
    #[arg(long, env = "VAULT_DEPLOY_BLOCK")]
    pub vault_deploy_block: Option<u64>,

    #[arg(long, env = "CHAIN_ID", default_value_t = 1)]
    pub chain_id: u64,

    /// Primary read node (tried first).
    #[arg(long, env = "PRIMARY_RPC", default_value = "https://eth.bearby.ru")]
    pub primary_rpc: Url,

    /// Comma-separated fallback read nodes, in order.
    #[arg(
        long,
        env = "FALLBACK_RPCS",
        default_value = "https://eth.drpc.org,https://ethereum-rpc.publicnode.com,https://1rpc.io/eth,https://rpc.flashbots.net"
    )]
    pub fallback_rpcs: String,

    /// Comma-separated private relays for sending transactions (empty = public broadcast only).
    #[arg(
        long,
        env = "PRIVATE_TX_RPCS",
        default_value = "https://rpc.flashbots.net/fast,https://rpc.mevblocker.io"
    )]
    pub private_tx_rpcs: String,

    /// Bearer token for the HTTP API (>= 32 chars).
    #[arg(long, env = "API_KEY", hide_env_values = true, hide = true)]
    pub api_key: String,

    #[arg(long, env = "API_BIND", default_value = "127.0.0.1:8080")]
    pub api_bind: SocketAddr,

    #[arg(long, env = "DB_PATH", default_value = "autobase.duckdb")]
    pub db_path: PathBuf,

    /// Strategy: target days the price should stay in range (width = σ_daily · √days).
    #[arg(long, env = "TARGET_DAYS_IN_RANGE", default_value_t = 20.0)]
    pub target_days_in_range: f64,

    /// Strategy: hours of hourly price samples used for volatility.
    #[arg(long, env = "VOL_LOOKBACK_HOURS", default_value_t = 168)]
    pub vol_lookback_hours: u64,

    /// Compound idle funds once worth at least this much (token1 base units; XAUT: 1e6 = 1 XAUT).
    #[arg(long, env = "COMPOUND_MIN_VALUE", default_value_t = 500_000.0)]
    pub compound_min_value: f64,

    /// Skip non-urgent actions above this base fee.
    #[arg(long, env = "MAX_BASE_FEE_GWEI", default_value_t = 30.0)]
    pub max_base_fee_gwei: f64,

    /// Hard cap on maxFeePerGas for any transaction, including bumps.
    #[arg(long, env = "MAX_FEE_GWEI", default_value_t = 100.0)]
    pub max_fee_gwei: f64,

    #[arg(long, env = "PRIORITY_FEE_GWEI", default_value_t = 1.0)]
    pub priority_fee_gwei: f64,

    /// Re-center even above MAX_BASE_FEE_GWEI once out of range this long.
    #[arg(long, env = "MAX_OUT_OF_RANGE_MINUTES", default_value_t = 120)]
    pub max_out_of_range_minutes: u64,

    #[arg(long, env = "POLL_INTERVAL_SECS", default_value_t = 12)]
    pub poll_interval_secs: u64,

    #[arg(long, env = "SNAPSHOT_INTERVAL_SECS", default_value_t = 300)]
    pub snapshot_interval_secs: u64,

    #[arg(long, env = "CONFIRMATIONS", default_value_t = 12)]
    pub confirmations: u64,

    #[arg(long, env = "RPC_TIMEOUT_MS", default_value_t = 5_000)]
    pub rpc_timeout_ms: u64,

    #[arg(long, env = "MAX_HEAD_LAG", default_value_t = 3)]
    pub max_head_lag: u64,

    /// Blocks to wait for inclusion before rebroadcasting / bumping.
    #[arg(long, env = "TX_WAIT_BLOCKS", default_value_t = 5)]
    pub tx_wait_blocks: u64,

    /// Seconds added to `now` for the on-chain rebalance deadline.
    #[arg(long, env = "TX_DEADLINE_SECS", default_value_t = 180)]
    pub tx_deadline_secs: u64,

    /// Warn when the keeper's ETH balance drops below this.
    #[arg(long, env = "MIN_KEEPER_BALANCE_ETH", default_value_t = 0.05)]
    pub min_keeper_balance_eth: f64,

    #[arg(long, env = "LOG_JSON", default_value_t = false)]
    pub log_json: bool,
}

/// Non-secret settings; safe to clone and share between tasks.
#[derive(Debug, Clone)]
pub struct Config {
    pub vault: Address,
    pub vault_deploy_block: Option<u64>,
    pub chain_id: u64,
    pub read_rpcs: Vec<Url>,
    pub private_tx_rpcs: Vec<Url>,
    pub api_bind: SocketAddr,
    pub db_path: PathBuf,
    pub target_days_in_range: f64,
    pub vol_lookback_hours: u64,
    pub compound_min_value: f64,
    pub max_base_fee_gwei: f64,
    pub max_fee_gwei: f64,
    pub priority_fee_gwei: f64,
    pub max_out_of_range: Duration,
    pub poll_interval: Duration,
    pub snapshot_interval: Duration,
    pub confirmations: u64,
    pub rpc_timeout: Duration,
    pub max_head_lag: u64,
    pub tx_wait_blocks: u64,
    pub tx_deadline_secs: u64,
    pub min_keeper_balance_eth: f64,
    pub log_json: bool,
}

/// Secrets, kept apart from `Config` so they never end up in shared state or logs.
pub struct Secrets {
    pub signer: PrivateKeySigner,
    pub api_key: ApiKey,
}

/// API bearer token. No `Debug`/`Display`; zeroized on drop.
pub struct ApiKey(Vec<u8>);

impl ApiKey {
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

impl Drop for ApiKey {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

fn parse_urls(list: &str) -> anyhow::Result<Vec<Url>> {
    list.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| {
            let url = Url::parse(s).map_err(|e| anyhow::anyhow!("invalid rpc url ({e})"))?;
            anyhow::ensure!(
                url.scheme() == "https" || url.host_str().is_some_and(|h| h == "127.0.0.1" || h == "localhost"),
                "rpc urls must be https (except localhost)"
            );
            Ok(url)
        })
        .collect()
}

impl Config {
    /// Validates the CLI and consumes its secrets (the CLI strings are zeroized).
    pub fn from_cli(mut cli: Cli) -> anyhow::Result<(Self, Secrets)> {
        let signer: Result<PrivateKeySigner, _> = cli.private_key.trim().parse();
        cli.private_key.zeroize();
        let signer = signer.map_err(|_| anyhow::anyhow!("{PRIVATE_KEY_ENV} is not a valid private key"))?;

        let api_key = std::mem::take(&mut cli.api_key).into_bytes();
        anyhow::ensure!(api_key.len() >= 32, "API_KEY must be at least 32 characters");
        let api_key = ApiKey(api_key);

        let mut read_rpcs = vec![cli.primary_rpc.clone()];
        read_rpcs.extend(parse_urls(&cli.fallback_rpcs)?);
        anyhow::ensure!(
            cli.primary_rpc.scheme() == "https"
                || cli
                    .primary_rpc
                    .host_str()
                    .is_some_and(|h| h == "127.0.0.1" || h == "localhost"),
            "PRIMARY_RPC must be https (except localhost)"
        );
        let private_tx_rpcs = parse_urls(&cli.private_tx_rpcs)?;

        anyhow::ensure!(cli.target_days_in_range > 0.0, "TARGET_DAYS_IN_RANGE must be > 0");
        anyhow::ensure!(cli.vol_lookback_hours >= 24, "VOL_LOOKBACK_HOURS must be >= 24");
        anyhow::ensure!(
            cli.max_fee_gwei > 0.0 && cli.priority_fee_gwei >= 0.0,
            "invalid gas caps"
        );
        anyhow::ensure!(
            cli.priority_fee_gwei <= cli.max_fee_gwei,
            "PRIORITY_FEE_GWEI > MAX_FEE_GWEI"
        );
        anyhow::ensure!(cli.tx_deadline_secs >= 30, "TX_DEADLINE_SECS must be >= 30");

        let config = Self {
            vault: cli.vault,
            vault_deploy_block: cli.vault_deploy_block,
            chain_id: cli.chain_id,
            read_rpcs,
            private_tx_rpcs,
            api_bind: cli.api_bind,
            db_path: cli.db_path,
            target_days_in_range: cli.target_days_in_range,
            vol_lookback_hours: cli.vol_lookback_hours,
            compound_min_value: cli.compound_min_value,
            max_base_fee_gwei: cli.max_base_fee_gwei,
            max_fee_gwei: cli.max_fee_gwei,
            priority_fee_gwei: cli.priority_fee_gwei,
            max_out_of_range: Duration::from_secs(cli.max_out_of_range_minutes * 60),
            poll_interval: Duration::from_secs(cli.poll_interval_secs.max(1)),
            snapshot_interval: Duration::from_secs(cli.snapshot_interval_secs.max(30)),
            confirmations: cli.confirmations,
            rpc_timeout: Duration::from_millis(cli.rpc_timeout_ms.max(500)),
            max_head_lag: cli.max_head_lag,
            tx_wait_blocks: cli.tx_wait_blocks.max(1),
            tx_deadline_secs: cli.tx_deadline_secs,
            min_keeper_balance_eth: cli.min_keeper_balance_eth,
            log_json: cli.log_json,
        };
        Ok((config, Secrets { signer, api_key }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cli(key: &str, api: &str) -> Cli {
        Cli::parse_from([
            "bot",
            "--private-key",
            key,
            "--vault",
            "0x0000000000000000000000000000000000000001",
            "--api-key",
            api,
            "--fallback-rpcs",
            "https://a.example, https://b.example,",
            "--private-tx-rpcs",
            "",
        ])
    }

    const KEY: &str = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";

    #[test]
    fn parses_valid_config() {
        let (c, _) = Config::from_cli(cli(KEY, &"k".repeat(32))).unwrap();
        assert_eq!(c.read_rpcs.len(), 3);
        assert!(c.private_tx_rpcs.is_empty());
    }

    #[test]
    fn rejects_short_api_key_and_bad_private_key() {
        assert!(Config::from_cli(cli(KEY, "short")).is_err());
        let err = Config::from_cli(cli("0xnope", &"k".repeat(32)))
            .err()
            .unwrap()
            .to_string();
        assert!(!err.contains("nope"), "error must not echo the key");
    }

    #[test]
    fn rejects_plain_http_rpc() {
        assert!(parse_urls("http://evil.example").is_err());
        assert!(parse_urls("http://127.0.0.1:8545").is_ok());
    }
}
