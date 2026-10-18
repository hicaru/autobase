// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

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
    }

    function _params() internal pure returns (AutoBaseVault.Params memory) {
        return AutoBaseVault.Params({
            halfWidthTicks: 600,
            twapWindow: 600,
            maxTwapDeviationTicks: 100,
            maxSlippageBps: 150,
            minRebalanceInterval: 1 hours
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

    function _withdrawAll(address user) internal returns (uint256 a0, uint256 a1) {
        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        (a0, a1) = vault.withdraw(shares, 0, 0, block.timestamp);
    }

    function _rebalance() internal {
        vm.prank(keeper);
        vault.rebalance(0, block.timestamp);
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
        bool zeroForOne = targetTick < _spotTick();
        deal(WBTC, address(this), 1_000e8);
        deal(XAUT, address(this), 100_000e6);
        inSwap = true;
        pool.swap(address(this), zeroForOne, type(int128).max, TickMath.getSqrtRatioAtTick(targetTick), "");
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

    function test_deposit_revertsWhenDust() public {
        deal(XAUT, alice, 100);
        vm.startPrank(alice);
        IERC20(XAUT).forceApprove(address(vault), 100);
        vm.expectRevert(AutoBaseVault.DepositTooSmall.selector);
        vault.deposit(0, 100, 0, block.timestamp);
        vm.stopPrank();
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
        vault.rebalance(0, block.timestamp);
    }

    function test_rebalance_revertsOnSpotManipulation() public {
        _deposit(alice, 0.2e8, 4e6);
        _rebalance();
        _skip(1 hours + 1);

        _movePrice(_spotTick() - 400); // same block: TWAP has not moved, spot has
        vm.prank(keeper);
        vm.expectPartialRevert(AutoBaseVault.TwapDeviation.selector);
        vault.rebalance(0, block.timestamp);
    }

    function test_rebalance_eventuallyNothingToDo() public {
        _deposit(alice, 0.2e8, 4e6);
        _rebalance();
        for (uint256 i; i < 5; ++i) {
            _skip(60);
            vm.prank(keeper);
            try vault.rebalance(0, block.timestamp) {}
            catch (bytes memory err) {
                assertEq(err, abi.encodeWithSelector(AutoBaseVault.NothingToDo.selector));
                return;
            }
        }
        revert("never reached NothingToDo");
    }

    function test_rebalance_revertsBelowMinLiquidity() public {
        _deposit(alice, 0.2e8, 4e6);
        vm.prank(keeper);
        vm.expectPartialRevert(AutoBaseVault.InsufficientLiquidity.selector);
        vault.rebalance(type(uint128).max, block.timestamp);
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
        vm.prank(alice);
        vm.expectPartialRevert(AutoBaseVault.InsufficientOutput.selector);
        vault.withdraw(shares, type(uint256).max, 0, block.timestamp);
    }

    function test_withdraw_revertsWithoutShares() public {
        _deposit(alice, 0.2e8, 4e6);
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

        // Push spot up to the deviation limit, deposit token1, push back, withdraw.
        _movePrice(_spotTick() + 95);
        uint256 shares = _deposit(attacker, 0, 10e6);
        _movePrice(_spotTick() - 95);
        (uint256 a0, uint256 a1) = _withdrawAll(attacker);

        assertGt(shares, 0);
        assertLe(_value(a0, a1), 10e6);
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
        _deposit(attacker, 0, 1_001);
        deal(XAUT, attacker, 100e6);
        vm.prank(attacker);
        IERC20(XAUT).safeTransfer(address(vault), 100e6);

        uint256 shares = _deposit(alice, 0, 1e6);
        assertGt(shares, 0);
        (, uint256 a1) = _withdrawAll(alice);
        assertApproxEqRel(a1, 1e6, 0.01e18); // victim loses < 1%
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
        vault.pause();
        vault.exitPosition();
        assertEq(vault.positionLiquidity(), 0);
        assertEq(IERC20(WBTC).balanceOf(address(this)), 0);

        (uint256 a0, uint256 a1) = _withdrawAll(alice);
        assertApproxEqRel(_value(a0, a1), _value(0.2e8, 4e6), 0.01e18);
    }

    function test_exitPosition_revertsWithoutPosition() public {
        vm.expectRevert(AutoBaseVault.NothingToDo.selector);
        vault.exitPosition();
    }
}
