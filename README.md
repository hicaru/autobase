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
cp .env.example .env                     # KEEPER, TOKEN_A, TOKEN_B, POOL_FEE, MIN_DEPOSIT_VALUE
forge script script/Deploy.s.sol --rpc-url https://eth.bearby.ru --sender <deployer>             # dry-run
forge script script/Deploy.s.sol --rpc-url https://eth.bearby.ru --browser --broadcast
```

In the browser wallet, set the network RPC to `https://eth.bearby.ru` (otherwise it sends via its default RPC).
Verify without an Etherscan key: `forge verify-contract <vault> AutoBaseVault --verifier sourcify --chain 1`.

Constructor: `(keeper, factory, tokenA, tokenB, fee, Params)`, deployer = owner. `Params` (set in `Deploy.s.sol`):

| Field | Value |
|---|---|
| `minHalfWidthTicks` / `maxHalfWidthTicks` | 420 / 1800 |
| `recenterThresholdBps` | 8000 |
| `twapWindow` | 600 s |
| `maxTwapDeviationTicks` | 100 |
| `maxSlippageBps` | 150 |
| `minRebalanceInterval` / `depositLock` | 1 h / 1 h |
| `minDepositValue` | `$MIN_DEPOSIT_VALUE` |

## Deployed (mainnet)

| | Address |
|---|---|
| Vault `AutoBaseVault` | [`0xb68852E2B545CDC8ec9B4ADEe72c029DB3635958`](https://etherscan.io/address/0xb68852E2B545CDC8ec9B4ADEe72c029DB3635958) |
| Pool (WBTC/XAUT 0.3%) | [`0xE8a1F39C16EEA2844E98f951D711Bb4Bb31557aD`](https://etherscan.io/address/0xE8a1F39C16EEA2844E98f951D711Bb4Bb31557aD) |
| Owner / deployer | `0xce883ef8803f2d021106C6510FA28E7b301Cdd87` |
| Deploy tx | `0x9997f67971fcb0e78321c54692b515ff76f44242c8327a46227d3a94ef812910` (block 26221220) |

## Keeper bot (`bot/`)

Rust service that watches the vault and calls `rebalance()`:
- **Reads:** your node first (`PRIMARY_RPC`, default `https://eth.bearby.ru`), with automatic failover to public nodes.
- **Transactions:** sent through private relays (Flashbots Protect / MEV-Blocker), with public rebroadcast and fee bumps if they aren't included.
- **Width:** chosen from realized volatility (`σ_daily · √TARGET_DAYS_IN_RANGE`) within the owner's bounds.
- **Analytics:** stored in SQLite and served by an API-key-protected JSON API.

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

