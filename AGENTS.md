# AGENTS.md — AutoBase

Rules for any human or AI agent touching this repository. **Security is the only priority.** When a rule here conflicts with convenience, gas savings, or "cleaner" code, the rule wins. When in doubt, stop and ask the owner.

---

## 1. What this project is

`AutoBaseVault` is a **public, permissionless LP vault** for one fixed Uniswap v3 pool on Ethereum mainnet (e.g. WBTC/XAUT 0.3%). It holds **other people's money**, so every change must be reviewed as if it were holding someone else's savings.

**Roles**

| Role | Who | Can do | Can never do |
|------|-----|---------|--------------|
| **owner** | deployer (`Ownable(msg.sender)`; 2-step transfer) | `setKeeper`, `setParams` (bounded), `pause`/`unpause`, emergency `exitPosition` (funds stay in the vault) | withdraw, move or redirect user funds, change the pool |
| **keeper** | bot on a VPS | `rebalance(minLiquidity, deadline)` only | anything else |
| **user** | anyone | `deposit(amount0, amount1, minShares, deadline)` → ERC20 shares (`ABLP`); `withdraw(shares, min0, min1, deadline)` → pro-rata token0 + token1 | affect other users' share value |

**Flow**
1. A user calls `approve` and then `deposit`. Funds sit **idle**, and the vault emits `Deposited`. A plain ERC20 `transfer` to the vault is a donation to all holders and credits nobody.
2. The bot sees `Deposited` (or a price move) and calls `rebalance()`:
   - if the range is unchanged, it compounds fees and idle funds into the current range (no cooldown);
   - if the range changed (or there is no position yet), it burns, collects, swaps to ratio and mints a new centered range (cooldown `minRebalanceInterval`).
3. `withdraw` burns shares and pays out the pro-rata part of idle funds, fees and position liquidity in **both tokens** (no swap). It **works while paused**.

```
src/AutoBaseVault.sol              vault (ERC20 shares, roles, deposit/withdraw, rebalance, callbacks)
src/libraries/RebalanceMath.sol    pure math: tick alignment, range, swap sizing, token0→token1 value
test/RebalanceMath.t.sol           unit + fuzz
test/AutoBaseVault.access.t.sol    roles, params bounds, pause, deadlines, callback spoofing (no fork)
test/AutoBaseVault.fork.t.sol      mainnet fork vs the real pool: flows + attack tests (needs ETH_RPC_URL)
script/Deploy.s.sol                deploy (deployer = owner, pool fixed)
```

Dependencies (git submodules, **pinned commits**): `forge-std`, `openzeppelin-contracts v5.4.0`, `Uniswap/v3-core@0.8`, `Uniswap/v3-periphery@0.8`.

---

## 2. Threat model

Anyone can deposit, so assume attackers with flash loans, MEV bots and unlimited patience. **These threats drive every design decision:**

| # | Threat | Mitigation (must never be weakened) |
|---|--------|-------------------------------------|
| T1 | **Share-price manipulation** (Gamma-style, 2024): move the pool price, deposit cheaply, withdraw more | Deposit values the vault at **both spot and TWAP** and mints `min(shares_spot, shares_twap)`, so moving the price can only hurt the depositor. Deposit also reverts if `|spot − TWAP| > maxTwapDeviationTicks`. Withdraw is purely pro-rata (no price input). Fork test: `test_attack_depositSandwichIsNotProfitable`. |
| T2 | **First-depositor / inflation attack** (donate to inflate share price, so the victim's shares round to 0) | `DEAD_SHARES` burned to `0x…dEaD` on first deposit, a high `INITIAL_SHARES_PER_UNIT` scale, user `minShares`, and `shares > 0` required. Fork test: `test_attack_inflationViaDonation`. |
| T3 | **Stale-TWAP arbitrage** (real price moved; TWAP lags) | Same min(spot, TWAP) pricing plus the deviation check on deposit. |
| T4 | **Unclaimed-fee theft** (deposit before fees are counted, withdraw after) | Every deposit and withdraw first pokes the position (`burn(…, 0)` + `collect`), so fees are in the books before shares are priced. |
| T5 | **Keeper hot key leaks** | Keeper can call **only** `rebalance()`. It cannot withdraw, set params, set the keeper or choose a recipient. Worst case: a range move once per `minRebalanceInterval` and swaps within `maxSlippageBps` of the TWAP. |
| T6 | **Sandwich of the rebalance swap** | Spot-vs-TWAP deviation check. Swap `sqrtPriceLimitX96` **and** min-out are derived from the **TWAP**. `maxTwapDeviationTicks < maxSlippageBps`. The bot uses a private mempool. |
| T7 | **Callback spoofing** | Callback requires `msg.sender == pool` **and** a transient in-flight flag set only by the vault right before `pool.mint` / `pool.swap`. |
| T8 | **Wrong / malicious pool** | Pool resolved via the canonical factory in the constructor; `immutable` afterwards. |
| T9 | **Owner compromise** | The owner has **no path to funds**: worst case is pause (withdraw still works), bounded params, or a hostile keeper (bounded as in T5). |
| T10 | **Exit blocked** | `withdraw` has no `whenNotPaused`, needs no keeper and no oracle. Never add a dependency that can block it. |
| T11 | **Token-level risk** | XAUT and WBTC issuers can freeze addresses, including the vault. Disclose this to users. |

### Invariants (tests must keep proving these)

- **I1** Funds leave the vault **only** to a share holder in `withdraw` (to `msg.sender`, pro-rata to burned shares) or to `pool` inside a vault-initiated mint/swap callback (exact owed amount).
- **I2** Neither `owner` nor `keeper` can move funds out of the vault.
- **I3** A deposit can never increase the value per share of the depositor's shares at the expense of others (shares = min over spot/TWAP, rounded down).
- **I4** `withdraw` is never blocked by pause, keeper state, or oracle state.
- **I5** Every swap is bounded by TWAP ± `maxSlippageBps` (price limit) and min-out vs. a TWAP quote.
- **I6** `params` always satisfy the bounds in `_setParams`.
- **I7** `totalSupply() > 0` implies `DEAD_SHARES` were minted to `0x…dEaD`.
- **I8** The vault never grants an ERC20 allowance to anyone and cannot receive ETH.

---

## 3. Hard rules (non-negotiable)

1. **No upgradability.** No proxies, no `delegatecall`, no `selfdestruct`, no `CREATE2` redeploy tricks. To fix a bug: pause, `exitPosition`, ask users to withdraw, and deploy a new vault.
2. **No arbitrary external calls.** No `call(data)` with caller-supplied target or calldata, no multicall, no "execute" escape hatch.
3. **No new privileged roles**, no widening of keeper or owner powers, and **never any owner path to user funds** (no `rescue`, `sweep`, `skim`, `emergencyWithdraw(to)`, fee recipient, etc.) without explicit approval in the PR description.
4. **Never use spot price (`slot0`) alone** for anything value-sensitive. Share pricing uses min(spot, TWAP), and swaps use the TWAP. Spot alone is only used for range centering, after the deviation check.
5. **Never set `sqrtPriceLimitX96` to `MIN_SQRT_RATIO+1` / `MAX_SQRT_RATIO-1`** (i.e. "no limit") on a vault swap.
6. **Never accept a recipient / `to` argument** in any function. Shares mint to `msg.sender`, withdrawals pay `msg.sender`, and liquidity belongs to `address(this)`.
7. **Every parameter has hard bounds** defined as `constant`s and checked in the setter. No unbounded `uint` knobs.
8. **Pinned compiler** `pragma solidity 0.8.28;` (no `^`, no ranges) in `src/`.
9. **No `unchecked`** blocks in `src/` unless you prove the bound in a comment and add a fuzz test for it.
10. **No inline assembly** in `src/`.
11. **No `tx.origin`**, no `block.timestamp` as a deadline (the keeper passes an explicit `deadline`), no `blockhash` randomness.
12. **No private keys** in code, `.env`, shell history, or CI. Deploy with `--account <keystore>` or `--ledger`. Never `--private-key`.
13. **No dependency bumps** (`forge update`, submodule moves) without reviewing the upstream diff and re-running the full fork suite.
14. **`forge build` runs with `deny = "warnings"`.** Do not silence lints globally. A per-line `// forge-lint: disable-next-line(...)` needs a written justification on the line above.
15. **Never gate `withdraw`** behind `whenNotPaused`, the keeper, the TWAP or any external condition.
16. **Share math changes require attack tests** (sandwich, inflation, rounding) on the fork suite before merge.

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
- ❌ **`renounceOwnership` called by mistake** → nobody can pause or rotate a leaked keeper key → ✅ never call it. If you touch ownership, consider overriding it to revert.
- ❌ **Owner "rescue" / "sweep" functions** for pool tokens → a rug path, even if well-intended → ✅ forbidden (rule 3.3). Donated tokens belong to share holders.
- ❌ **Same key for owner and keeper** → the T5 mitigation is void → ✅ the deploy script enforces `keeper != deployer`. Deploy from cold storage (Ledger or keystore), never from the bot box.

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
- ❌ **Ignoring token admin powers** (freeze, blacklist, pause, upgradeable token proxy) → funds stuck → ✅ documented accepted risk (T11). Monitor issuer announcements.
- ❌ **Crediting deposits by `balanceOf` diff without a `deposit()` call**, or trusting the `amount` argument → fee-on-transfer and donation confusion → ✅ `_pull` measures the actual balance delta of `safeTransferFrom` in the same call. Raw transfers are donations.

### 5.5 Vault share accounting (ERC4626-style risks)
- ❌ **Valuing the vault at spot (`slot0`) when minting shares** → flash-loan price push, cheap shares (Gamma, Jan 2024) → ✅ `min(shares@spot, shares@TWAP)` plus the deviation check.
- ❌ **Valuing at TWAP only** → when the real price moves, the stale TWAP lets arbitrageurs mint at an outdated price → ✅ use the min of both, never one alone.
- ❌ **Position amounts computed at a manipulable price** (`getAmountsForLiquidity(slot0)`) inside share math → ✅ compute holdings at each price you value with (spot and TWAP separately).
- ❌ **No dead shares / virtual offset** → first-depositor inflation attack → ✅ `DEAD_SHARES` minted to `0x…dEaD`, high initial share scale, `DepositTooSmall`.
- ❌ **Rounding shares up on deposit or assets up on withdraw** → value leaks out one wei at a time, which is profitable at scale → ✅ round **down** on both (`mulDiv` floors).
- ❌ **No `minShares` / `min0` / `min1` / `deadline`** on user functions → users are sandwiched → ✅ all four are mandatory parameters.
- ❌ **Pricing shares before collecting fees** → depositors steal accrued fees → ✅ poke (`burn 0` + `collect`) first.
- ❌ **Reading `totalSupply()` after `_mint` / `_burn`** in the same calculation → wrong ratio → ✅ snapshot `supply` before mutating it.
- ❌ **Withdraw that swaps to a single token** → the exit can be sandwiched and manipulated → ✅ pro-rata in both tokens, no swap.
- ❌ **Withdraw gated by pause, oracle or keeper** → funds held hostage → ✅ withdraw is unconditional (rule 3.15).
- ❌ **Share price views (`totalAmounts`) consumed by other protocols** → read-only manipulation → ✅ views are spot-based and informational. Document it; never use them for pricing.
- ❌ **Mint/burn ratio of liquidity ≠ share ratio** → withdrawer takes more than their slice → ✅ `burnLiquidity = L * shares / supply` (floor), using the same `supply` snapshot.

### 5.6 Math
- ❌ **Division before multiplication** → precision loss → ✅ multiply first, or `mulDiv`.
- ❌ **Wrong rounding direction** → value leaks to the counterparty → ✅ round against the caller / in the vault's favour.
- ❌ **Unsafe downcasts** (`uint128(x)`, `int24(x)`, `uint256(int)`) → silent truncation or sign flip → ✅ `SafeCast` / explicit bound checks.
- ❌ **Intermediate overflow in Q96 / Q192 math** (`sqrtP * sqrtP`) → revert or wrong result → ✅ `FullMath.mulDiv` in two steps (see `RebalanceMath.toToken1`).
- ❌ **`unchecked` for "gas"** without a proof → wraparound → ✅ checked arithmetic by default.
- ❌ **Negative tick division rounding toward zero** → off-by-one-spacing range → ✅ `floorTick` rounds toward −∞.
- ❌ **Bps ≈ ticks treated as exact** → 1 tick ≈ 1.0001× ≈ 1 bp only approximately → ✅ keep a margin. Enforce min-out separately.

### 5.7 General Solidity
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

### 5.8 Operational
- ❌ **Private key in `.env`, scripts or CLI flags** → leaked via history or logs → ✅ `cast wallet import` keystore or Ledger.
- ❌ **Bot sends `rebalance` through the public mempool** → sandwich within the slippage bound → ✅ private RPC (Flashbots Protect, MEV-Blocker).
- ❌ **Bot sets `deadline` far in the future or `minLiquidity = 0` blindly** → stale transaction executes later at a worse state → ✅ deadline ≈ now + 1–2 blocks. Simulate (`eth_call`) first and pass `minLiquidity` ≈ 99% of the simulated result.
- ❌ **Bot retries on revert in a tight loop** → gas burn → ✅ treat `TwapDeviation`, `Cooldown` and `NothingToDo` as "wait", and back off.
- ❌ **Deploy without a fork dry-run** → ✅ always `forge script … --fork-url` first.
- ❌ **Deploying from a hot key** → the deployer **is** the owner → ✅ deploy with `--ledger` or a cold keystore. Verify `owner()` and `keeper()` on-chain after deploy.
- ❌ **Changing the pool of a live vault** → orphaned liquidity, mispriced shares → ✅ impossible: the pool is `immutable`. Deploy a new vault instead.
- ❌ **No emergency path** → ✅ `pause()` stops deposits and the keeper. `exitPosition()` moves liquidity to idle, and users can always `withdraw()`.
- ❌ **Bot ignores `Deposited` events** → user funds sit idle, earning nothing → ✅ the bot calls `rebalance()` after deposits. Same-range compounding has no cooldown.
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
```

## 7. Definition of done for any change

- [ ] `forge build` is clean (no warnings, no lint errors) and `forge fmt --check` passes.
- [ ] All tests pass, **including the fork suite** with a real `ETH_RPC_URL`.
- [ ] Every new revert path has a test.
- [ ] Invariants I1–I8 still hold, and none of the rules in §3 is violated.
- [ ] No new antipattern from §5 was introduced.
- [ ] Slither shows no new high or medium findings, or each one is justified in the PR.
- [ ] Any change to roles, params bounds or the swap / oracle logic is called out explicitly in the PR description.
