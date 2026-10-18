# AutoBase

Public Uniswap v3 LP vault for one fixed pool (WBTC/XAUT 0.3% on mainnet). Users deposit WBTC and/or XAUT
and receive `ABLP` shares; a keeper bot calls `rebalance()` to deploy idle deposits and keep the range
centered on the current price. Withdrawals are pro-rata in both tokens and always available.

| Role | Can |
|------|-----|
| owner (deployer) | `setKeeper`, `setParams`, `pause`/`unpause`, emergency `exitPosition` — **no access to funds** |
| keeper (bot) | `rebalance(minLiquidity, deadline)` only |
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
