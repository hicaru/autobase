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

/// @dev Runs only when ETH_RPC_URL is set. Pinned block for determinism.
contract AutoBaseVaultForkTest is Test {
    using SafeERC20 for IERC20;

    IUniswapV3Factory internal constant FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    uint24 internal constant FEE = 3000;
    uint256 internal constant FORK_BLOCK = 26_220_000;

    AutoBaseVault internal vault;
    IUniswapV3Pool internal pool;
    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    bool internal inSwap;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);

        vault = new AutoBaseVault(owner, keeper, FACTORY, _params());
        vm.prank(owner);
        vault.setPool(WBTC, XAUT, FEE);
        pool = vault.pool();
        assertEq(address(pool), FACTORY.getPool(WBTC, XAUT, FEE));
        assertEq(address(vault.token0()), WBTC); // WBTC < XAUT
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

    function _fund(uint256 wbtc, uint256 xaut) internal {
        deal(WBTC, address(vault), wbtc);
        deal(XAUT, address(vault), xaut);
    }

    function _rebalance() internal {
        vm.prank(keeper);
        vault.rebalance(0, block.timestamp);
    }

    function _spotTick() internal view returns (int24 tick) {
        (, tick,,,,,) = pool.slot0();
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

    // ------------------------------------------------------------------

    function test_initialRebalance_mintsCenteredPosition() public {
        _fund(0.2e8, 4e6);
        _rebalance();
        _assertCentered();
        assertEq(vault.lastRebalance(), block.timestamp);
    }

    function test_initialRebalance_singleSidedDeposit() public {
        _fund(0.1e8, 0);
        _rebalance();
        _assertCentered();
        // Most value deployed: idle WBTC is a small fraction of the deposit.
        assertLt(IERC20(WBTC).balanceOf(address(vault)), 0.01e8);
    }

    function test_rebalance_recentersAfterPriceMove() public {
        _fund(0.2e8, 4e6);
        _rebalance();
        int24 oldLower = vault.tickLower();

        _movePrice(_spotTick() - 1_500); // well below the range
        assertLt(_spotTick(), oldLower);
        vm.warp(block.timestamp + 1 hours + 1); // TWAP catches up, cooldown passes
        vm.roll(block.number + 300);

        _rebalance();
        _assertCentered();
        assertLt(vault.tickLower(), oldLower);
    }

    function test_rebalance_revertsOnSpotManipulation() public {
        _fund(0.2e8, 4e6);
        _rebalance();
        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(block.number + 300);

        // Same-block price push: TWAP has not moved, spot has.
        _movePrice(_spotTick() - 400);
        vm.prank(keeper);
        vm.expectPartialRevert(AutoBaseVault.TwapDeviation.selector);
        vault.rebalance(0, block.timestamp);
    }

    function test_rebalance_revertsWhenRangeUnchanged() public {
        _fund(0.2e8, 4e6);
        _rebalance();
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(keeper);
        vm.expectRevert(AutoBaseVault.NothingToDo.selector);
        vault.rebalance(0, block.timestamp);
    }

    function test_rebalance_revertsDuringCooldown() public {
        _fund(0.2e8, 4e6);
        _rebalance();
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(keeper);
        vm.expectRevert(AutoBaseVault.Cooldown.selector);
        vault.rebalance(0, block.timestamp);
    }

    function test_rebalance_revertsBelowMinLiquidity() public {
        _fund(0.2e8, 4e6);
        vm.prank(keeper);
        vm.expectPartialRevert(AutoBaseVault.InsufficientLiquidity.selector);
        vault.rebalance(type(uint128).max, block.timestamp);
    }

    function test_rebalance_largeSwapIsCappedByTwapLimit() public {
        // Selling ~half of 50 WBTC into a pool holding ~9 WBTC cannot clear within the TWAP bound:
        // the swap stops at the TWAP-derived price limit and the remainder stays idle.
        _fund(50e8, 0);
        uint32[] memory ago = new uint32[](2);
        ago[0] = _params().twapWindow;
        (int56[] memory cum,) = pool.observe(ago);
        int24 twapTick = int24((cum[1] - cum[0]) / int56(uint56(ago[0])));

        _rebalance();

        assertGe(_spotTick(), twapTick - int24(uint24(_params().maxSlippageBps)) - 1);
        assertGt(IERC20(WBTC).balanceOf(address(vault)), 10e8);
        assertGt(vault.positionLiquidity(), 0);
    }

    function test_setPool_revertsWithOpenPosition() public {
        _fund(0.2e8, 4e6);
        _rebalance();
        vm.prank(owner);
        vm.expectRevert(AutoBaseVault.PositionOpen.selector);
        vault.setPool(WBTC, XAUT, 500);
    }

    function test_exitAndWithdraw_returnsFundsToOwner() public {
        _fund(0.2e8, 4e6);
        _rebalance();

        vm.startPrank(owner);
        vault.exitPosition();
        assertEq(vault.positionLiquidity(), 0);
        uint256 w = IERC20(WBTC).balanceOf(address(vault));
        uint256 x = IERC20(XAUT).balanceOf(address(vault));
        vault.withdraw(IERC20(WBTC), w);
        vault.withdraw(IERC20(XAUT), x);
        vm.stopPrank();

        assertEq(IERC20(WBTC).balanceOf(owner), w);
        assertEq(IERC20(XAUT).balanceOf(owner), x);
        assertEq(IERC20(WBTC).balanceOf(address(vault)), 0);
        assertEq(IERC20(XAUT).balanceOf(address(vault)), 0);
        // Value roughly preserved (pool fee on the initial swap only).
        uint256 valueOut = RebalanceMath.toToken1(w, TickMath.getSqrtRatioAtTick(_spotTick())) + x;
        uint256 valueIn = RebalanceMath.toToken1(0.2e8, TickMath.getSqrtRatioAtTick(_spotTick())) + 4e6;
        assertApproxEqRel(valueOut, valueIn, 0.01e18);
    }

    function test_exitPosition_revertsWithoutPosition() public {
        vm.prank(owner);
        vm.expectRevert(AutoBaseVault.NothingToDo.selector);
        vault.exitPosition();
    }

    function test_callbackSpoof_revertsEvenFromRealPool() public {
        // The real pool calling outside of a vault-initiated operation must be rejected.
        _fund(0.2e8, 4e6);
        vm.prank(address(pool));
        vm.expectRevert(AutoBaseVault.UnauthorizedCallback.selector);
        vault.uniswapV3SwapCallback(1e8, 0, "");
    }

    function test_keeperCannotMoveFunds() public {
        _fund(0.2e8, 4e6);
        _rebalance();
        vm.startPrank(keeper);
        vm.expectRevert();
        vault.withdraw(IERC20(WBTC), 1);
        vm.expectRevert();
        vault.exitPosition();
        vm.expectRevert();
        vault.setKeeper(keeper);
        vm.stopPrank();
    }
}
