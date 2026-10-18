// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

import {AutoBaseVault} from "../src/AutoBaseVault.sol";
import {RebalanceMath} from "../src/libraries/RebalanceMath.sol";

/// @dev Runs only when ETH_RPC_URL is set (archive node). Pinned block for determinism.
///      The test contract is the deployer, hence the owner.
contract AutoBaseVaultForkTest is Test {
    using SafeERC20 for IERC20;

    IUniswapV3Factory internal constant FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    uint24 internal constant FEE = 3000;
    uint256 internal constant FORK_BLOCK = 26_220_000;
    int24 internal constant WIDTH = 600;

    AutoBaseVault internal vault;
    IUniswapV3Pool internal pool;
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");
    uint160 internal sqrtRef; // fork-start price, used to value balances in tests
    bool internal inSwap;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);

        vault = new AutoBaseVault(keeper, FACTORY, WBTC, XAUT, FEE, _params());
        pool = vault.pool();
        assertEq(address(pool), FACTORY.getPool(WBTC, XAUT, FEE));
        assertEq(address(vault.token0()), WBTC); // WBTC < XAUT
        assertEq(vault.owner(), address(this));
        (sqrtRef,,,,,,) = pool.slot0();
        // Funds for simulated market / attacker swaps; never re-dealt so swap costs can be measured.
        deal(WBTC, address(this), 1_000e8);
        deal(XAUT, address(this), 100_000e6);
    }

    function _params() internal pure returns (AutoBaseVault.Params memory) {
        return AutoBaseVault.Params({
            minHalfWidthTicks: 60,
            maxHalfWidthTicks: 1800,
            recenterThresholdBps: 8000,
            twapWindow: 600,
            maxTwapDeviationTicks: 100,
            maxSlippageBps: 150,
            minRebalanceInterval: 1 hours,
            depositLock: 1 hours,
            minDepositValue: 1e4 // 0.01 XAUT
        });
    }

    // ------------------------------------------------------------------ helpers

    function _deposit(address user, uint256 wbtc, uint256 xaut) internal returns (uint256 shares) {
        deal(WBTC, user, wbtc);
        deal(XAUT, user, xaut);
        vm.startPrank(user);
        IERC20(WBTC).forceApprove(address(vault), wbtc);
        IERC20(XAUT).forceApprove(address(vault), xaut);
        shares = vault.deposit(wbtc, xaut, 0, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Waits out the user's post-deposit lock.
    function _unlock(address user) internal {
        uint256 until = vault.lockedUntil(user);
        if (block.timestamp < until) _skip(until - block.timestamp);
    }

    function _withdrawAll(address user) internal returns (uint256 a0, uint256 a1) {
        _unlock(user);
        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        (a0, a1) = vault.withdraw(shares, 0, 0, block.timestamp);
    }

    function _rebalance() internal {
        vm.prank(keeper);
        vault.rebalance(WIDTH, 0, block.timestamp);
    }

    function _value(uint256 a0, uint256 a1) internal view returns (uint256) {
        return RebalanceMath.toToken1(a0, sqrtRef) + a1;
    }

    function _spotTick() internal view returns (int24 tick) {
        (, tick,,,,,) = pool.slot0();
    }

    function _skip(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 12);
    }

    /// @dev Moves the pool price to `targetTick` with an external swap (simulates the market / an attacker).
    function _movePrice(int24 targetTick) internal {
        if (targetTick == _spotTick()) return;
        bool zeroForOne = targetTick < _spotTick();
        inSwap = true;
        pool.swap(address(this), zeroForOne, type(int128).max, TickMath.getSqrtRatioAtTick(targetTick), "");
        inSwap = false;
    }

    /// @dev Moves the pool price back to an exact sqrt price.
    function _moveToSqrt(uint160 target) internal {
        (uint160 sqrtP,,,,,,) = pool.slot0();
        if (sqrtP == target) return;
        inSwap = true;
        pool.swap(address(this), target < sqrtP, type(int128).max, target, "");
        inSwap = false;
    }

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        require(inSwap && msg.sender == address(pool), "cb");
        if (d0 > 0) IERC20(WBTC).safeTransfer(msg.sender, SafeCast.toUint256(d0));
        if (d1 > 0) IERC20(XAUT).safeTransfer(msg.sender, SafeCast.toUint256(d1));
    }

    function _assertCentered() internal view {
        int24 tick = _spotTick();
        assertLe(vault.tickLower(), tick);
        assertGt(vault.tickUpper(), tick);
        assertEq(vault.tickLower() % pool.tickSpacing(), 0);
        assertEq(vault.tickUpper() % pool.tickSpacing(), 0);
        assertGt(vault.positionLiquidity(), 0);
    }

    // ------------------------------------------------------------------ deposit / rebalance

    function test_deposit_mintsSharesAndStaysIdle() public {
        uint256 shares = _deposit(alice, 0.2e8, 4e6);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.balanceOf(address(0xdEaD)), vault.DEAD_SHARES());
        assertEq(vault.positionLiquidity(), 0);
        assertEq(IERC20(WBTC).balanceOf(address(vault)), 0.2e8);
    }

    function test_deposit_singleToken() public {
        assertGt(_deposit(alice, 0.1e8, 0), 0);
        assertGt(_deposit(bob, 0, 2e6), 0);
    }

    function test_deposit_revertsBelowMinShares() public {
        deal(WBTC, alice, 0.1e8);
        vm.startPrank(alice);
        IERC20(WBTC).forceApprove(address(vault), 0.1e8);
        vm.expectPartialRevert(AutoBaseVault.InsufficientShares.selector);
        vault.deposit(0.1e8, 0, type(uint256).max, block.timestamp);
        vm.stopPrank();
    }

    function test_deposit_revertsBelowMinDeposit() public {
        uint256 amount = _params().minDepositValue - 1;
        deal(XAUT, alice, amount);
        vm.startPrank(alice);
        IERC20(XAUT).forceApprove(address(vault), amount);
        vm.expectRevert(AutoBaseVault.DepositTooSmall.selector);
        vault.deposit(0, amount, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_deposit_minDepositChangeableByOwner() public {
        AutoBaseVault.Params memory p = _params();
        p.minDepositValue = 1e6; // 1 XAUT
        vault.setParams(p);

        deal(XAUT, alice, 0.5e6);
        vm.startPrank(alice);
        IERC20(XAUT).forceApprove(address(vault), 0.5e6);
        vm.expectRevert(AutoBaseVault.DepositTooSmall.selector);
        vault.deposit(0, 0.5e6, 0, block.timestamp);
        vm.stopPrank();

        assertGt(_deposit(bob, 0, 1e6), 0);
    }

    function test_deposit_minDepositUsesLowerPriceView() public {
        _deposit(alice, 0.2e8, 4e6);
        _skip(1 hours);
        _movePrice(_spotTick() + 90); // spot values WBTC ~0.9% higher than TWAP

        (int24 twapTick,) = OracleLibrary.consult(address(pool), _params().twapWindow);
        uint160 sqrtTwap = TickMath.getSqrtRatioAtTick(twapTick);
        uint256 minValue = _params().minDepositValue;
        // Binary search: `sats` = smallest WBTC amount worth >= min at TWAP, `lo` = sats - 1.
        uint256 lo;
        uint256 sats = 1;
        while (RebalanceMath.toToken1(sats, sqrtTwap) < minValue) sats *= 2;
        lo = sats / 2;
        while (lo + 1 < sats) {
            uint256 mid = (lo + sats) / 2;
            if (RebalanceMath.toToken1(mid, sqrtTwap) < minValue) lo = mid;
            else sats = mid;
        }
        (uint160 sqrtSpot,,,,,,) = pool.slot0();
        assertGe(RebalanceMath.toToken1(lo, sqrtSpot), minValue); // `lo` passes at spot ...

        deal(WBTC, bob, lo + sats);
        vm.startPrank(bob);
        IERC20(WBTC).forceApprove(address(vault), lo + sats);
        vm.expectRevert(AutoBaseVault.DepositTooSmall.selector); // ... but the lower TWAP view rejects it
        vault.deposit(lo, 0, 0, block.timestamp);
        assertGt(vault.deposit(sats, 0, 0, block.timestamp), 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ deposit lock

    function test_lock_blocksWithdrawAndTransfer() public {
        uint256 shares = _deposit(alice, 0.2e8, 4e6);
        uint256 until = vault.lockedUntil(alice);
        assertEq(until, block.timestamp + _params().depositLock);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(AutoBaseVault.SharesLocked.selector, until));
        vault.withdraw(shares, 0, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(AutoBaseVault.SharesLocked.selector, until));
        // call is expected to revert, so there is no return value to check
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        vault.transfer(bob, shares);
        vm.stopPrank();
    }

    function test_lock_expires() public {
        uint256 shares = _deposit(alice, 0.2e8, 4e6);
        _skip(_params().depositLock);
        vm.prank(alice);
        assertTrue(vault.transfer(bob, shares / 2));
        vm.prank(bob); // receiver is not locked
        vault.withdraw(shares / 2, 0, 0, block.timestamp);
        vm.prank(alice);
        vault.withdraw(shares - shares / 2, 0, 0, block.timestamp);
    }

    function test_lock_newDepositRelocks() public {
        _deposit(alice, 0.2e8, 4e6);
        _skip(_params().depositLock);
        _deposit(alice, 0.1e8, 0);
        vm.prank(alice);
        vm.expectPartialRevert(AutoBaseVault.SharesLocked.selector);
        vault.withdraw(1, 0, 0, block.timestamp);
    }

    function test_rebalance_deploysIdleDeposits() public {
        _deposit(alice, 0.2e8, 4e6);
        _rebalance();
        _assertCentered();
        assertEq(vault.lastRebalance(), block.timestamp);
    }

    function test_rebalance_singleSidedDepositIsDeployed() public {
        _deposit(alice, 0.1e8, 0);
        _rebalance();
        _assertCentered();
        assertLt(IERC20(WBTC).balanceOf(address(vault)), 0.001e8);
    }

    function test_rebalance_compoundsNewDepositIntoSameRange() public {
        _deposit(alice, 0.2e8, 4e6);
        _rebalance();
        int24 lower = vault.tickLower();
        uint128 liqBefore = vault.positionLiquidity();

        _deposit(bob, 0.1e8, 0);
        _skip(60); // no range cooldown needed for compounding
        _rebalance();

        assertEq(vault.tickLower(), lower);
        assertGt(vault.positionLiquidity(), liqBefore);
    }

    function test_rebalance_recentersAfterPriceMove() public {
        _deposit(alice, 0.2e8, 4e6);
        _rebalance();
        int24 oldLower = vault.tickLower();

        _movePrice(_spotTick() - 1_500); // well below the range
        assertLt(_spotTick(), oldLower);
        _skip(1 hours + 1); // TWAP catches up, cooldown passes

        _rebalance();
        _assertCentered();
        assertLt(vault.tickLower(), oldLower);
    }

    function test_rebalance_rangeMoveRespectsCooldown() public {
        _deposit(alice, 0.2e8, 4e6);
        _rebalance();
        _movePrice(_spotTick() - 1_500);
        _skip(30 minutes);
        vm.prank(keeper);
        vm.expectRevert(AutoBaseVault.Cooldown.selector);
        vault.rebalance(WIDTH, 0, block.timestamp);
    }

    function test_rebalance_revertsOnSpotManipulation() public {
        _deposit(alice, 0.2e8, 4e6);
        _rebalance();
        _skip(1 hours + 1);

        _movePrice(_spotTick() - 400); // same block: TWAP has not moved, spot has
        vm.prank(keeper);
        vm.expectPartialRevert(AutoBaseVault.TwapDeviation.selector);
        vault.rebalance(WIDTH, 0, block.timestamp);
    }

    function test_rebalance_eventuallyNothingToDo() public {
        _deposit(alice, 0.2e8, 4e6);
        _rebalance();
        for (uint256 i; i < 5; ++i) {
            _skip(60);
            vm.prank(keeper);
            try vault.rebalance(WIDTH, 0, block.timestamp) {}
            catch (bytes memory err) {
                assertEq(err, abi.encodeWithSelector(AutoBaseVault.NothingToDo.selector));
                return;
            }
        }
        revert("never reached NothingToDo");
    }

    function test_rebalance_usesKeeperWidth() public {
        _deposit(alice, 0.2e8, 4e6);
        vm.prank(keeper);
        vault.rebalance(300, 0, block.timestamp);
        int24 span = vault.tickUpper() - vault.tickLower();
        assertGe(span, 600); // 2 * 300, aligned outward to the 60-tick spacing
        assertLe(span, 720);
        _assertCentered();
    }

    function test_rebalance_returnsAddedLiquidity() public {
        _deposit(alice, 0.2e8, 4e6);
        vm.prank(keeper);
        uint128 added = vault.rebalance(WIDTH, 0, block.timestamp);
        assertEq(added, vault.positionLiquidity());
    }

    function test_trigger_blocksRecenterWhileCentered() public {
        _deposit(alice, 0.2e8, 4e6);
        _rebalance();
        int24 lower = vault.tickLower();
        int24 upper = vault.tickUpper();

        _movePrice(_spotTick() + 200); // ~1/3 of the half width: below the 80% trigger
        _skip(2 hours); // cooldown passed, TWAP caught up
        _deposit(bob, 0.1e8, 0); // something to compound

        vm.prank(keeper);
        vault.rebalance(1200, 0, block.timestamp); // different width requested ...
        assertEq(vault.tickLower(), lower); // ... but the range must not move
        assertEq(vault.tickUpper(), upper);
    }

    function test_trigger_allowsRecenterPastThreshold() public {
        _deposit(alice, 0.2e8, 4e6);
        _rebalance();
        int24 lower = vault.tickLower();
        int24 upper = vault.tickUpper();
        int24 center = (lower + upper) / 2;

        // Push past 80% of the half width while staying inside the range.
        _movePrice(center + (upper - center) * 85 / 100);
        assertLt(_spotTick(), upper);
        _skip(2 hours);

        _rebalance();
        assertTrue(vault.tickLower() != lower);
        _assertCentered();
    }

    function test_rebalance_revertsOnInvalidWidth() public {
        _deposit(alice, 0.2e8, 4e6);
        vm.startPrank(keeper);
        vm.expectRevert(AutoBaseVault.InvalidWidth.selector);
        vault.rebalance(59, 0, block.timestamp);
        vm.expectRevert(AutoBaseVault.InvalidWidth.selector);
        vault.rebalance(1801, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_rebalance_revertsBelowMinLiquidity() public {
        _deposit(alice, 0.2e8, 4e6);
        vm.prank(keeper);
        vm.expectPartialRevert(AutoBaseVault.InsufficientLiquidity.selector);
        vault.rebalance(WIDTH, type(uint128).max, block.timestamp);
    }

    function test_rebalance_largeSwapIsCappedByTwapLimit() public {
        // Selling ~half of 50 WBTC into a pool holding ~9 WBTC cannot clear within the TWAP bound:
        // the swap stops at the TWAP-derived price limit and the remainder stays idle.
        _deposit(alice, 50e8, 0);
        uint32[] memory ago = new uint32[](2);
        ago[0] = _params().twapWindow;
        (int56[] memory cum,) = pool.observe(ago);
        int24 twapTick = int24((cum[1] - cum[0]) / int56(uint56(ago[0])));

        _rebalance();

        assertGe(_spotTick(), twapTick - int24(uint24(_params().maxSlippageBps)) - 1);
        assertGt(IERC20(WBTC).balanceOf(address(vault)), 10e8);
        assertGt(vault.positionLiquidity(), 0);
    }

    // ------------------------------------------------------------------ withdraw

    function test_withdraw_returnsValue() public {
        _deposit(alice, 0.2e8, 4e6);
        _rebalance();
        (uint256 a0, uint256 a1) = _withdrawAll(alice);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(IERC20(WBTC).balanceOf(alice), a0);
        assertEq(IERC20(XAUT).balanceOf(alice), a1);
        // Only loss: pool fee on the rebalance swap + rounding.
        assertApproxEqRel(_value(a0, a1), _value(0.2e8, 4e6), 0.01e18);
    }

    function test_withdraw_idleOnly() public {
        _deposit(alice, 0.2e8, 4e6);
        (uint256 a0, uint256 a1) = _withdrawAll(alice);
        // First depositor forfeits DEAD_SHARES (~0.001 XAUT of value here).
        assertApproxEqRel(a0, 0.2e8, 0.001e18);
        assertApproxEqRel(a1, 4e6, 0.001e18);
    }

    function test_withdraw_worksWhilePaused() public {
        _deposit(alice, 0.2e8, 4e6);
        _rebalance();
        vault.pause();
        (uint256 a0, uint256 a1) = _withdrawAll(alice);
        assertGt(_value(a0, a1), 0);
    }

    function test_withdraw_revertsBelowMins() public {
        uint256 shares = _deposit(alice, 0.2e8, 4e6);
        _unlock(alice);
        vm.prank(alice);
        vm.expectPartialRevert(AutoBaseVault.InsufficientOutput.selector);
        vault.withdraw(shares, type(uint256).max, 0, block.timestamp);
    }

    function test_withdraw_revertsWithoutShares() public {
        _deposit(alice, 0.2e8, 4e6);
        _unlock(alice);
        vm.prank(attacker);
        vm.expectRevert();
        vault.withdraw(1, 0, 0, block.timestamp);
    }

    function test_twoUsers_fairShares() public {
        _deposit(alice, 0.2e8, 4e6);
        _rebalance();
        _deposit(bob, 0.2e8, 4e6);
        _skip(60);
        _rebalance();

        (uint256 a0, uint256 a1) = _withdrawAll(alice);
        (uint256 b0, uint256 b1) = _withdrawAll(bob);
        assertApproxEqRel(_value(a0, a1), _value(b0, b1), 0.01e18);
    }

    // ------------------------------------------------------------------ attacks

    function test_attack_depositSandwichIsNotProfitable() public {
        _deposit(alice, 1e8, 20e6);
        _rebalance();
        _skip(1 hours);
        _assertSandwichUnprofitable(95, 0, 10e6);
        _assertSandwichUnprofitable(-95, 0.5e8, 0);
    }

    /// @dev Attacker pushes spot by `move` ticks, deposits, restores the exact price, waits out the lock and
    ///      withdraws. Full P&L (deposit/withdraw + manipulation swaps) must be <= 0.
    function _assertSandwichUnprofitable(int24 move, uint256 dep0, uint256 dep1) internal {
        (uint160 sqrtStart,,,,,,) = pool.slot0();
        sqrtRef = sqrtStart; // value everything at the price the attacker restores
        uint256 before = _value(IERC20(WBTC).balanceOf(address(this)), IERC20(XAUT).balanceOf(address(this)));
        _movePrice(_spotTick() + move);
        uint256 shares = _deposit(attacker, dep0, dep1);
        _moveToSqrt(sqrtStart);
        uint256 afterSwaps = _value(IERC20(WBTC).balanceOf(address(this)), IERC20(XAUT).balanceOf(address(this)));
        // Round trip to the exact same price: the swapper can only have paid fees.
        assertLe(afterSwaps, before, "round trip gained");
        uint256 swapCost = before - afterSwaps;

        (uint256 a0, uint256 a1) = _withdrawAll(attacker);
        assertGt(shares, 0);
        assertLe(_value(a0, a1), _value(dep0, dep1) + swapCost, "sandwich profitable");
    }

    function test_attack_depositBeyondDeviationReverts() public {
        _deposit(alice, 1e8, 20e6);
        _rebalance();
        _skip(1 hours);
        _movePrice(_spotTick() + 300);

        deal(XAUT, attacker, 10e6);
        vm.startPrank(attacker);
        IERC20(XAUT).forceApprove(address(vault), 10e6);
        vm.expectPartialRevert(AutoBaseVault.TwapDeviation.selector);
        vault.deposit(0, 10e6, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_attack_inflationViaDonation() public {
        // Attacker makes the smallest allowed first deposit, then donates a large amount.
        _deposit(attacker, 0, _params().minDepositValue);
        deal(XAUT, attacker, 100e6);
        vm.prank(attacker);
        IERC20(XAUT).safeTransfer(address(vault), 100e6);

        uint256 shares = _deposit(alice, 0, 1e6);
        assertGt(shares, 0);
        (, uint256 a1) = _withdrawAll(alice);
        assertApproxEqRel(a1, 1e6, 0.01e18); // victim loses < 1%
    }

    function test_attack_feeSnipingBlockedByLock() public {
        _deposit(alice, 1e8, 20e6);
        _rebalance();
        _skip(1 hours);

        // Attacker sees a big swap coming, deposits a large idle amount right before it ...
        uint256 shares = _deposit(attacker, 0, 100e6);
        (uint160 sqrtStart,,,,,,) = pool.slot0();
        _movePrice(_spotTick() + 90);
        _moveToSqrt(sqrtStart); // ... fees accrue to the vault position ...

        // ... and cannot withdraw (or move shares) to grab them.
        vm.startPrank(attacker);
        vm.expectPartialRevert(AutoBaseVault.SharesLocked.selector);
        vault.withdraw(shares, 0, 0, block.timestamp);
        vm.expectPartialRevert(AutoBaseVault.SharesLocked.selector);
        // call is expected to revert, so there is no return value to check
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        vault.transfer(bob, shares);
        vm.stopPrank();
    }

    function test_attack_callbackSpoofFromRealPool() public {
        _deposit(alice, 0.2e8, 4e6);
        vm.prank(address(pool));
        vm.expectRevert(AutoBaseVault.UnauthorizedCallback.selector);
        vault.uniswapV3SwapCallback(1e8, 0, "");
    }

    function test_keeperCannotMoveFunds() public {
        _deposit(alice, 0.2e8, 4e6);
        _rebalance();
        vm.startPrank(keeper);
        vm.expectRevert();
        vault.withdraw(1, 0, 0, block.timestamp);
        vm.expectRevert();
        vault.exitPosition();
        vm.expectRevert();
        vault.setKeeper(keeper);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ owner emergency

    function test_exitPosition_keepsFundsInVault() public {
        _deposit(alice, 0.2e8, 4e6);
        _rebalance();
        uint256 ownerWbtc = IERC20(WBTC).balanceOf(address(this));
        uint256 ownerXaut = IERC20(XAUT).balanceOf(address(this));
        vault.pause();
        vault.exitPosition();
        assertEq(vault.positionLiquidity(), 0);
        assertEq(IERC20(WBTC).balanceOf(address(this)), ownerWbtc); // nothing reached the owner
        assertEq(IERC20(XAUT).balanceOf(address(this)), ownerXaut);

        (uint256 a0, uint256 a1) = _withdrawAll(alice);
        assertApproxEqRel(_value(a0, a1), _value(0.2e8, 4e6), 0.01e18);
    }

    function test_exitPosition_revertsWithoutPosition() public {
        vm.expectRevert(AutoBaseVault.NothingToDo.selector);
        vault.exitPosition();
    }

    // ------------------------------------------------------------------ fork fuzz

    /// forge-config: default.fuzz.runs = 40
    function testFuzz_sandwichNeverProfitable(int24 move, uint256 dep0, uint256 dep1) public {
        move = int24(bound(move, -95, 95));
        dep0 = bound(dep0, 0, 2e8);
        dep1 = bound(dep1, 0, 40e6);
        vm.assume(_value(dep0, dep1) >= 2 * _params().minDepositValue);

        _deposit(alice, 1e8, 20e6);
        _rebalance();
        _skip(1 hours);
        _assertSandwichUnprofitable(move, dep0, dep1);
    }

    /// forge-config: default.fuzz.runs = 40
    function testFuzz_twoUsersFairAndSolvent(uint256 a0, uint256 a1, uint256 b0, uint256 b1) public {
        a0 = bound(a0, 0, 1e8);
        a1 = bound(a1, 0, 20e6);
        b0 = bound(b0, 0, 1e8);
        b1 = bound(b1, 0, 20e6);
        vm.assume(_value(a0, a1) >= 1e6 && _value(b0, b1) >= 1e6);

        _deposit(alice, a0, a1);
        _rebalance();
        _skip(20 minutes); // let the TWAP absorb the vault's own rebalance swap
        _deposit(bob, b0, b1);
        vm.prank(keeper);
        try vault.rebalance(WIDTH, 0, block.timestamp) {} catch {} // may be NothingToDo for tiny deposits

        (uint256 oa0, uint256 oa1) = _withdrawAll(alice);
        (uint256 ob0, uint256 ob1) = _withdrawAll(bob);
        uint256 inA = _value(a0, a1);
        uint256 inB = _value(b0, b1);
        uint256 outA = _value(oa0, oa1);
        uint256 outB = _value(ob0, ob1);

        // Each user keeps >= 97% (pool fee + bounded swap impact), and nobody creates value from nothing.
        assertGe(outA, inA * 97 / 100, "alice lost too much");
        assertGe(outB, inB * 97 / 100, "bob lost too much");
        assertLe(outA + outB, inA + inB, "value created");

        // Solvency: only dead-share dust remains.
        (uint256 r0, uint256 r1) = vault.totalAmounts(); // idle + position
        assertLe(_value(r0, r1), (inA + inB) / 1000 + 1e4, "residual too large");
        assertEq(vault.totalSupply(), vault.DEAD_SHARES());
    }
}
