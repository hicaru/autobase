# AutoBase

Public Uniswap v3 LP vault for one fixed pool (WBTC/XAUT 0.3% on mainnet). Users deposit WBTC and/or XAUT
and receive `ABLP` shares; a keeper bot calls `rebalance()` to deploy idle deposits and keep the range
centered on the current price. Withdrawals are pro-rata in both tokens and always available.

| Role | Can |
|------|-----|
| owner (deployer) | `setKeeper`, `setParams`, `pause`/`unpause`, emergency `exitPosition` — **no access to funds** |
| keeper (bot) | `rebalance(halfWidthTicks, minLiquidity, deadline)` only (width within owner bounds) |
| user (anyone) | `deposit(amount0, amount1, minShares, deadline)` after `approve` (≥ `minDepositValue`; shares locked for `depositLock`); `withdraw(shares, min0, min1, deadline)` |

> A plain token `transfer` to the vault credits nobody — always use `approve` + `deposit`.

Security rules & antipatterns: [`AGENTS.md`](AGENTS.md) — read before changing anything.

```bash
forge build
forge test                               # fork suite runs only with ETH_RPC_URL (archive node)
cp .env.example .env                     # fill KEEPER / ETH_RPC_URL / MIN_DEPOSIT_VALUE
forge script script/Deploy.s.sol --fork-url $ETH_RPC_URL --sender <deployer>          # dry-run
forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --ledger --broadcast --verify # deployer = owner
```

## Keeper bot (`bot/`)

Rust service that watches the vault and calls `rebalance()`:
- **Reads:** your node first (`PRIMARY_RPC`, default `https://eth.bearby.ru`), with automatic failover to public nodes.
- **Transactions:** sent through private relays (Flashbots Protect / MEV-Blocker), with public rebroadcast and fee bumps if they aren't included.
- **Width:** chosen from realized volatility (`σ_daily · √TARGET_DAYS_IN_RANGE`) within the owner's bounds.
- **Analytics:** stored in DuckDB and served by an API-key-protected JSON API.

```bash
cd bot && cp .env.example .env   # fill KEEPER_PRIVATE_KEY, VAULT_ADDRESS, API_KEY (openssl rand -hex 32)
cargo run --release
curl -H "Authorization: Bearer $API_KEY" http://127.0.0.1:8080/status
```

API (all except `/healthz` need the bearer key):

| Route | What it shows |
|---|---|
| `/status` | position, tick, range, keeper balance, current decision, last tx |
| `/strategy` | volatility, chosen width, distance to the re-center trigger |
| `/rewards?days=30` | fees earned (daily + total), fee APR, time in range, rebalance count, gas spent |
| `/rebalances`, `/deposits`, `/withdrawals`, `/swaps`, `/actions`, `/snapshots` | history (`?limit=&offset=`) |
| `/price-history?from=&to=` | hourly price samples |
| `/rpc` | per-endpoint health (latency, head, errors) |

Production: `bot/deploy/autobase-bot.service` (hardened systemd unit, `Restart=always`).

