# AGENTS.md — AutoBase

Rules for any human or AI agent touching this repository. **Security is the only priority.** When a rule here conflicts with convenience, gas savings, or "cleaner" code, the rule wins. When in doubt, stop and ask the owner.

---

## 1. What this project is

`AutoBaseVault` is a **single-owner** vault that holds one Uniswap v3 concentrated-liquidity position on Ethereum mainnet (e.g. WBTC/XAUT 0.3%). An off-chain bot (the **keeper**) calls `rebalance()`, and the vault itself:

1. checks spot price vs. pool TWAP,
2. computes a new range centered on the current tick,
3. burns + collects the old position,
4. swaps to the target ratio (TWAP-bounded),
5. mints the new position.

```
src/AutoBaseVault.sol              vault (roles, rebalance, callbacks)
src/libraries/RebalanceMath.sol    pure math: tick alignment, range, swap sizing
test/RebalanceMath.t.sol           unit + fuzz
test/AutoBaseVault.access.t.sol    roles, params bounds, pause, callback spoofing (no fork)
test/AutoBaseVault.fork.t.sol      mainnet fork vs the real pool (needs ETH_RPC_URL)
script/Deploy.s.sol                deploy → setPool → transferOwnership(OWNER)
```

Dependencies (git submodules, **pinned commits**): `forge-std`, `openzeppelin-contracts v5.4.0`, `Uniswap/v3-core@0.8`, `Uniswap/v3-periphery@0.8`.

---

## 2. Threat model

Personal use means there are no third-party depositors, so there is no share math, no inflation attack, and no user-fund commingling. **These threats remain and drive every design decision:**

| # | Threat | Mitigation (must never be weakened) |
|---|--------|-------------------------------------|
| T1 | **Keeper hot key leaks** (it lives on a server) | Keeper can call **only** `rebalance()`. It cannot withdraw, set params, set the pool, set itself, or choose any recipient. Worst case: it rebalances once per `minRebalanceInterval` and pays swap fees within `maxSlippageBps`. |
| T2 | **Price manipulation / sandwich** of the rebalance swap | Spot-vs-TWAP deviation check; swap `sqrtPriceLimitX96` **and** min-out are derived from the **TWAP**, never spot; `maxTwapDeviationTicks < maxSlippageBps`; the bot submits through a private mempool (Flashbots Protect / MEV-Blocker). |
| T3 | **Callback spoofing** (`uniswapV3MintCallback` / `uniswapV3SwapCallback`) | Callback requires `msg.sender == pool` **and** a transient in-flight flag set only by the vault right before `pool.mint` / `pool.swap`. |
| T4 | **Wrong / malicious pool** | Pool is resolved only through the canonical factory `getPool(tokenA, tokenB, fee)`; raw pool addresses are never accepted. Pool can change only with no open position. |
| T5 | **Owner key loss / compromise** | Owner should be a hardware wallet or Safe. Ownership is 2-step (`Ownable2Step`). |
| T6 | **Token-level risk** | XAUT (Tether) and WBTC have admin freeze/blacklist powers. A frozen vault cannot be fixed on-chain; keep exposure sized accordingly. |

### Invariants (tests must keep proving these)

- **I1** Funds leave the vault **only** to `owner()` (via `withdraw`) or to the configured `pool` (inside a vault-initiated mint/swap callback, exact owed amount).
- **I2** `keeper` cannot change any state except via `rebalance()`.
- **I3** Every swap is bounded by TWAP ± `maxSlippageBps` (price limit) and min-out vs. a TWAP quote.
- **I4** `params` always satisfy the bounds in `_setParams` (constants in the contract).
- **I5** `setPool` is impossible while `positionLiquidity() != 0`.
- **I6** The vault never holds an ERC20 allowance to anyone. It uses direct pool calls plus callbacks, so there are no `approve` calls at all.
- **I7** The vault cannot receive ETH (no `receive` / `fallback`).

---

## 3. Hard rules (non-negotiable)

1. **No upgradability.** No proxies, no `delegatecall`, no `selfdestruct`, no `CREATE2` redeploy tricks. To fix a bug: exit, withdraw, redeploy.
2. **No arbitrary external calls.** No `call(data)` with caller-supplied target or calldata, no multicall, no "execute" escape hatch.
3. **No new privileged roles** and no widening of keeper powers without explicit owner approval in the PR description.
4. **Never use spot price (`slot0`) as an oracle** for anything value-sensitive. Spot is only used for range centering, and only after the TWAP-deviation check.
5. **Never set `sqrtPriceLimitX96` to `MIN_SQRT_RATIO+1` / `MAX_SQRT_RATIO-1`** (i.e. "no limit") on a vault swap.
6. **Never accept a recipient / `to` argument** in any function. Recipient is always `owner()` or `address(this)`.
7. **Every parameter has hard bounds** defined as `constant`s and checked in the setter. No unbounded `uint` knobs.
8. **Pinned compiler** `pragma solidity 0.8.28;` (no `^`, no ranges) in `src/`.
9. **No `unchecked`** blocks in `src/` unless you prove the bound in a comment and add a fuzz test for it.
10. **No inline assembly** in `src/`.
11. **No `tx.origin`**, no `block.timestamp` as a deadline (the keeper passes an explicit `deadline`), no `blockhash` randomness.
12. **No private keys** in code, `.env`, shell history, or CI. Deploy with `--account <keystore>` or `--ledger`. Never `--private-key`.
13. **No dependency bumps** (`forge update`, submodule moves) without reviewing the upstream diff and re-running the full fork suite.
14. **`forge build` runs with `deny = "warnings"`.** Do not silence lints globally. A per-line `// forge-lint: disable-next-line(...)` needs a written justification on the line above.

---

## 4. Mandatory practices

- **Checks-Effects-Interactions.** State (`lastRebalance`, `tickLower/Upper`) is written before any pool interaction. `nonReentrant` (transient) on every state-changing external function.
- **SafeERC20** for every transfer. Never trust the `bool` return of raw `transfer` / `transferFrom`.
- **SafeCast** for every narrowing or sign-changing cast (`int256 → uint256`, `uint256 → uint128`, …). Never cast raw.
- **FullMath.mulDiv** for any `a * b / c` that can exceed 256 bits (prices, sqrt prices, Q96/Q128 math).
- **Multiply before divide.** Choose the rounding direction deliberately, in the vault's favour. Comment it when it is not obvious.
- **Custom errors** (no `require` strings) and **events for every state change**.
- **Zero-address checks** on every address setter.
- **NatSpec** on every external / public function.
- **Tests for every new branch**: each `revert` gets a test that triggers it. Use `vm.expectRevert(selector)`, not bare `expectRevert()`, where possible.
- **Fork tests against the real pool** for any change touching rebalance, swap, mint, burn or collect. Pin the fork block.
- **Fuzz pure math** (`RebalanceMath`) with ≥ 1000 runs. Add invariant tests for any new stateful logic.
- **Dry-run every deploy** on a fork (`forge script … --fork-url`) before `--broadcast`.

---

## 5. Antipattern catalogue

Each entry follows the format **❌ antipattern → why it's dangerous → ✅ do instead**. Reviewers reject any PR that introduces one of these.

### 5.1 Access control
- ❌ **Missing access modifier** on a state-changing function → anyone calls it → ✅ explicit `onlyOwner` / `onlyKeeper`. The access test must enumerate every external function for every non-authorized caller.
- ❌ **`tx.origin` for auth** → phishing contract relays the call → ✅ `msg.sender`.
- ❌ **One-step `transferOwnership`** → a typo bricks the vault forever → ✅ `Ownable2Step`.
- ❌ **Keeper can set params / recipient / pool / keeper** → leaked bot key = drained vault → ✅ keeper only calls `rebalance`.
- ❌ **Unprotected `initialize()`** (proxy pattern) → front-run takeover → ✅ constructor only, no proxies.
- ❌ **`renounceOwnership` callable by mistake** → no one can ever withdraw → ✅ never call it. If you touch ownership, consider overriding it to revert.
- ❌ **Same key for owner and keeper** → the T1 mitigation is void → ✅ the deploy script enforces `owner != keeper`. The owner is cold storage.

### 5.2 Reentrancy
- ❌ **External call before state update** (classic) → re-enter with stale state → ✅ CEI + `nonReentrant`.
- ❌ **Cross-function reentrancy** (A's external call re-enters B, which shares state) → ✅ guard **all** state-changing externals with the same lock.
- ❌ **Read-only reentrancy** (a view returns inconsistent state mid-operation) → ✅ do not expose views that other protocols could price against mid-call; this vault's views are informational only.
- ❌ **Hook tokens** (ERC777, ERC1363, tokens with transfer callbacks) → reentrancy via `transfer` → ✅ only whitelisted plain ERC20 pairs. Never point the vault at a pool with a hook token.
- ❌ **Callback without in-flight guard** → anyone (even the real pool on another user's swap) can trigger payment → ✅ `msg.sender == pool && _expectingCallback`.

### 5.3 Uniswap v3–specific
- ❌ **`slot0` spot price as an oracle** → flash-loan manipulable in one block → ✅ TWAP via `observe` with window ≥ `MIN_TWAP_WINDOW`.
- ❌ **`amountOutMinimum = 0`** → 100% sandwichable → ✅ min-out from a TWAP quote minus `maxSlippageBps`.
- ❌ **`sqrtPriceLimitX96 = 0` or extreme** → swap walks the whole curve → ✅ limit = TWAP tick ∓ slippage ticks.
- ❌ **Min-out computed from spot or from a quoter in the same tx** → the attacker moves both → ✅ TWAP only.
- ❌ **Unchecked callback `msg.sender`** → attacker calls the callback and gets paid → ✅ verify the pool **and** the in-flight flag. Never verify via a `data`-encoded pool key alone.
- ❌ **Accepting a pool address from input** → fake pool steals approvals or funds → ✅ resolve via the canonical factory.
- ❌ **Too-short TWAP window or low observation cardinality** → TWAP ≈ spot → ✅ `twapWindow ≥ 60s`. Make sure `observationCardinality` covers the window; if needed, call `pool.increaseObservationCardinalityNext(n)` (anyone can).
- ❌ **Deviation bound ≥ slippage bound** → the price limit can land on the wrong side of spot (`SPL` revert) or allow trading at a manipulated price → ✅ `maxTwapDeviationTicks < maxSlippageBps` (enforced).
- ❌ **Ticks not aligned to `tickSpacing`** → `mint` reverts → ✅ `RebalanceMath.floorTick`, then clamp to usable MIN/MAX.
- ❌ **Assuming token order** (e.g. "WBTC is always token0") → inverted price math → ✅ read `pool.token0()` / `token1()`; fork tests assert the order.
- ❌ **Burn without collect** → principal and fees stay owed in the pool → ✅ always `burn` then `collect(type(uint128).max, …)`.
- ❌ **Liquidity sized to exact balances** → `mint` rounds owed amounts up → transfer short by 1–2 wei → revert → ✅ keep `MINT_DUST` back.
- ❌ **`block.timestamp` as a swap deadline** → no protection at all → ✅ keeper-supplied `deadline`.
- ❌ **Rebalancing on every block / tiny moves** → fee bleed → ✅ `minRebalanceInterval` plus `NothingToDo` when the range is unchanged.
- ❌ **Fee-on-transfer / rebasing tokens** → owed amount ≠ received amount → accounting breaks → ✅ not supported. Never configure such a pair.
- ❌ **Ignoring partial fills** → assuming `amountIn` was fully consumed → ✅ check slippage on the actual `amount0/1Delta`.

### 5.4 ERC20
- ❌ **Raw `transfer` / `transferFrom` without checking the return** (USDT returns nothing, some return `false`) → ✅ `SafeERC20`.
- ❌ **`approve(spender, type(uint256).max)`** to routers or managers → one bug there drains the vault → ✅ no approvals at all (direct pool + callback).
- ❌ **USDT-style approve-to-nonzero** → reverts → ✅ `forceApprove` if an approval ever becomes necessary (it shouldn't).
- ❌ **Assuming 18 decimals** → WBTC = 8, XAUT = 6 → ✅ work in raw units; never hardcode decimals into price math.
- ❌ **Ignoring token admin powers** (freeze, blacklist, pause, upgradeable token proxy) → funds stuck → ✅ documented accepted risk (T6). Monitor issuer announcements.
- ❌ **`balanceOf(this)` used as accounting truth when others can donate** → manipulation of share math → ✅ acceptable here **only** because there are no shares. Never add share accounting on top of `balanceOf`.

### 5.5 Math
- ❌ **Division before multiplication** → precision loss → ✅ multiply first, or `mulDiv`.
- ❌ **Wrong rounding direction** → value leaks to the counterparty → ✅ round against the caller / in the vault's favour.
- ❌ **Unsafe downcasts** (`uint128(x)`, `int24(x)`, `uint256(int)`) → silent truncation or sign flip → ✅ `SafeCast` / explicit bound checks.
- ❌ **Intermediate overflow in Q96 / Q192 math** (`sqrtP * sqrtP`) → revert or wrong result → ✅ `FullMath.mulDiv` in two steps (see `RebalanceMath.toToken1`).
- ❌ **`unchecked` for "gas"** without a proof → wraparound → ✅ checked arithmetic by default.
- ❌ **Negative tick division rounding toward zero** → off-by-one-spacing range → ✅ `floorTick` rounds toward −∞.
- ❌ **Bps ≈ ticks treated as exact** → 1 tick ≈ 1.0001× ≈ 1 bp only approximately → ✅ keep a margin. Enforce min-out separately.

### 5.6 General Solidity
- ❌ **`delegatecall` to anything** → full storage takeover → ✅ forbidden.
- ❌ **Arbitrary `call` with user data** → approve / transfer on behalf of the vault → ✅ forbidden.
- ❌ **`selfdestruct`** → deprecated semantics, force-sends ETH → ✅ forbidden.
- ❌ **Signature schemes** without nonce, chainId, deadline or EIP-712 → replay or malleability → ✅ none in this project. If ever added: EIP-712 + nonces + `ECDSA.recover` (rejects malleable signatures).
- ❌ **`abi.encodePacked` with multiple dynamic types** for hashing → collisions → ✅ `abi.encode`. The only `encodePacked` here is Uniswap's fixed-size position key (`address,int24,int24`) and must match the pool's own derivation.
- ❌ **Unbounded loops over storage arrays** → gas DoS → ✅ no loops over growing storage.
- ❌ **Revert inside a loop of external calls** (one failure blocks all) → ✅ avoid; this vault has no such loops.
- ❌ **Strict equality on `address(this).balance`** → force-sent ETH breaks it → ✅ never rely on ETH balance.
- ❌ **Front-runnable two-step operations** without a commit or deadline → ✅ explicit deadlines and min-outs.
- ❌ **Timestamp dependence for critical logic within ~15s** → validator skew → ✅ cooldowns measured in minutes or hours only.
- ❌ **Variable shadowing / uninitialized storage pointers** → silent bugs → ✅ compiler warnings are errors.
- ❌ **Storage layout changes in upgradeable contracts** → slot collisions → ✅ no upgradeability (rule 3.1).
- ❌ **`msg.value` reused in a loop** → double-spend of the same ETH → ✅ the vault is not payable.
- ❌ **Missing events** on admin changes → invisible tampering → ✅ emit for every setter, then monitor them off-chain.
- ❌ **Magic numbers** → ✅ named `constant`s.
- ❌ **Silent `fallback` / `receive`** → stuck ETH, unexpected entry point → ✅ none.
- ❌ **Floating pragma** → untested compiler in production → ✅ `0.8.28` pinned.
- ❌ **Relying on `private` for secrecy** → all storage is public → ✅ never store secrets on-chain.
- ❌ **Using `transfer()` / `send()` for ETH** (2300 gas) → ✅ not applicable. If ETH is ever handled, use `Address.sendValue` with a reentrancy guard.

### 5.7 Operational
- ❌ **Private key in `.env`, scripts or CLI flags** → leaked via history or logs → ✅ `cast wallet import` keystore or Ledger.
- ❌ **Bot sends `rebalance` through the public mempool** → sandwich within the slippage bound → ✅ private RPC (Flashbots Protect, MEV-Blocker).
- ❌ **Bot sets `deadline` far in the future or `minLiquidity = 0` blindly** → stale transaction executes later at a worse state → ✅ deadline ≈ now + 1–2 blocks. Simulate (`eth_call`) first and pass `minLiquidity` ≈ 99% of the simulated result.
- ❌ **Bot retries on revert in a tight loop** → gas burn → ✅ treat `TwapDeviation`, `Cooldown` and `NothingToDo` as "wait", and back off.
- ❌ **Deploy without a fork dry-run** → ✅ always `forge script … --fork-url` first.
- ❌ **Forgetting `acceptOwnership()`** → the deployer hot key stays owner → ✅ the owner accepts right after deploy, then verify `owner()` on-chain.
- ❌ **Switching pools with an open position** → orphaned liquidity → ✅ `exitPosition`, then `setPool` (enforced).
- ❌ **No emergency path** → ✅ `pause()` stops the keeper. `exitPosition()` and `withdraw()` keep working while paused.
- ❌ **Unpinned or unreviewed dependency updates** → supply-chain risk → ✅ submodules pinned to a commit; review diffs before bumping.
- ❌ **Large position in a thin pool** → the swap hits the TWAP limit, the fill is partial and capital sits idle → ✅ size the position relative to pool depth. Watch the `Swapped` events.

---

## 6. Commands

```bash
forge build                                  # warnings & lints are errors
forge fmt --check
forge test                                   # unit + fuzz (fork suite skips without ETH_RPC_URL)
ETH_RPC_URL=<archive rpc> forge test         # full suite incl. mainnet fork (pinned block)
forge coverage --ir-minimum                  # coverage report
slither . --filter-paths lib                 # static analysis (pip install slither-analyzer)

# deploy (dry-run first!)
forge script script/Deploy.s.sol --fork-url $ETH_RPC_URL --sender <deployer>
forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --account <keystore> --broadcast --verify
# then, from OWNER: acceptOwnership()
```

## 7. Definition of done for any change

- [ ] `forge build` is clean (no warnings, no lint errors) and `forge fmt --check` passes.
- [ ] All tests pass, **including the fork suite** with a real `ETH_RPC_URL`.
- [ ] Every new revert path has a test.
- [ ] Invariants I1–I7 still hold, and none of the rules in §3 is violated.
- [ ] No new antipattern from §5 was introduced.
- [ ] Slither shows no new high or medium findings, or each one is justified in the PR.
- [ ] Any change to roles, params bounds or the swap / oracle logic is called out explicitly in the PR description.
