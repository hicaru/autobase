# AutoBase

Single-owner Uniswap v3 vault that keeps one concentrated-liquidity position centered on the current price.
An off-chain keeper bot calls `rebalance(minLiquidity, deadline)`; the vault checks spot vs. TWAP, picks the
new range, burns/collects, swaps to ratio (TWAP-bounded), and re-mints.

- Contract: `src/AutoBaseVault.sol`
- Security rules & antipatterns: [`AGENTS.md`](AGENTS.md) — read before changing anything.

```bash
forge build
forge test                               # fork suite runs only with ETH_RPC_URL (archive node)
cp .env.example .env                     # then fill OWNER / KEEPER / ETH_RPC_URL
forge script script/Deploy.s.sol --fork-url $ETH_RPC_URL --sender <deployer>   # dry-run
```

After deploy, `OWNER` must call `acceptOwnership()`.
