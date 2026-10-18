// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import {RebalanceMath} from "../src/libraries/RebalanceMath.sol";

contract RebalanceMathTest is Test {
    function test_floorTick() public pure {
        assertEq(RebalanceMath.floorTick(0, 60), 0);
        assertEq(RebalanceMath.floorTick(59, 60), 0);
        assertEq(RebalanceMath.floorTick(60, 60), 60);
        assertEq(RebalanceMath.floorTick(-1, 60), -60);
        assertEq(RebalanceMath.floorTick(-60, 60), -60);
        assertEq(RebalanceMath.floorTick(-61, 60), -120);
    }

    function testFuzz_floorTick(int24 tick, uint8 spacingSeed) public pure {
        int24 spacing = _spacing(spacingSeed);
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK));
        int24 f = RebalanceMath.floorTick(tick, spacing);
        assertEq(f % spacing, 0);
        assertLe(f, tick);
        assertGt(f + spacing, tick);
    }

    function testFuzz_rangeAround_containsTickAndAligned(int24 tick, int24 halfWidth, uint8 spacingSeed) public pure {
        int24 spacing = _spacing(spacingSeed);
        tick = int24(bound(tick, -800_000, 800_000));
        halfWidth = int24(bound(halfWidth, 10, 50_000));
        (int24 lower, int24 upper) = RebalanceMath.rangeAround(tick, halfWidth, spacing);
        assertEq(lower % spacing, 0);
        assertEq(upper % spacing, 0);
        assertLe(lower, tick);
        assertGt(upper, tick);
        assertGe(lower, TickMath.MIN_TICK);
        assertLe(upper, TickMath.MAX_TICK);
    }

    function test_rangeAround_clampsToUsableBounds() public pure {
        (int24 lower, int24 upper) = RebalanceMath.rangeAround(TickMath.MIN_TICK + 5, 1_000, 60);
        assertEq(lower, -887220);
        assertGt(upper, lower);
        (lower, upper) = RebalanceMath.rangeAround(TickMath.MAX_TICK - 5, 1_000, 60);
        assertEq(upper, 887220);
        assertLt(lower, upper);
    }

    function test_computeSwap_outsideRange() public pure {
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(-600);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(600);
        (bool z, uint256 amt) = RebalanceMath.computeSwap(5, 7, TickMath.getSqrtRatioAtTick(-1_000), sqrtA, sqrtB);
        assertFalse(z);
        assertEq(amt, 7);
        (z, amt) = RebalanceMath.computeSwap(5, 7, TickMath.getSqrtRatioAtTick(1_000), sqrtA, sqrtB);
        assertTrue(z);
        assertEq(amt, 5);
    }

    function test_computeSwap_symmetricRangeAtParity() public pure {
        // At price 1 with a symmetric range the position is ~50/50; all-token0 must sell ~half.
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        (bool z, uint256 amt) = RebalanceMath.computeSwap(
            1e18, 0, sqrtP, TickMath.getSqrtRatioAtTick(-600), TickMath.getSqrtRatioAtTick(600)
        );
        assertTrue(z);
        assertApproxEqRel(amt, 0.5e18, 0.001e18);
    }

    /// After a frictionless swap at the current price, almost all value must fit into the range.
    function testFuzz_computeSwap_fillsRange(uint128 bal0, uint128 bal1, int24 tick, int24 halfWidth) public pure {
        tick = int24(bound(tick, -200_000, 200_000));
        halfWidth = int24(bound(halfWidth, 10, 50_000));
        (int24 lower, int24 upper) = RebalanceMath.rangeAround(tick, halfWidth, 1);
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(tick);
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(upper);

        uint256 b0 = bound(bal0, 0, 1e30);
        uint256 b1 = bound(bal1, 0, 1e30);
        uint256 value = RebalanceMath.toToken1(b0, sqrtP) + b1;
        vm.assume(value > 1e12);

        (bool z, uint256 amt) = RebalanceMath.computeSwap(b0, b1, sqrtP, sqrtA, sqrtB);
        if (z) {
            assertLe(amt, b0);
            b0 -= amt;
            b1 += RebalanceMath.toToken1(amt, sqrtP);
        } else {
            assertLe(amt, b1);
            b1 -= amt;
            b0 += FullMath.mulDiv(FullMath.mulDiv(amt, 1 << 96, sqrtP), 1 << 96, sqrtP);
        }

        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtA, sqrtB, b0, b1);
        (uint256 used0, uint256 used1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, liq);
        uint256 usedValue = RebalanceMath.toToken1(used0, sqrtP) + used1;
        // <= 0.01% of value left idle, plus a few wei of integer rounding (matters at extreme prices).
        assertLe(usedValue, value);
        assertGe(usedValue + RebalanceMath.toToken1(4, sqrtP) + 4, value - value / 10_000);
    }

    function _spacing(uint8 seed) private pure returns (int24) {
        int24[4] memory s = [int24(1), int24(10), int24(60), int24(200)];
        return s[seed % 4];
    }
}

