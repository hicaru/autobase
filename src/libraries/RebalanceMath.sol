// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

/// @title RebalanceMath
/// @notice Pure helpers for computing the target range and the swap required to fill it.
library RebalanceMath {
    /// @dev Reference liquidity used to sample the token ratio of a range. Large enough for precision,
    ///      small enough that no intermediate overflows for any valid sqrt price.
    uint128 internal constant REF_LIQUIDITY = uint128(1 << 96);

    /// @notice Rounds `tick` towards negative infinity to a multiple of `spacing`.
    function floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    /// @notice Range of roughly `2 * halfWidth` ticks around `tick`, aligned to `spacing` and clamped to
    ///         the usable tick bounds. Guarantees `lower <= tick < upper` when not clamped.
    function rangeAround(int24 tick, int24 halfWidth, int24 spacing) internal pure returns (int24 lower, int24 upper) {
        lower = floorTick(tick - halfWidth, spacing);
        upper = floorTick(tick + halfWidth, spacing) + spacing;

        int24 minUsable = -floorTick(TickMath.MAX_TICK, spacing);
        int24 maxUsable = floorTick(TickMath.MAX_TICK, spacing);
        if (lower < minUsable) lower = minUsable;
        if (upper > maxUsable) upper = maxUsable;
    }

    /// @notice True when the range should move: `tick` is outside [`lower`, `upper`) or its distance from the
    ///         range center is at least `thresholdBps` of the half width.
    function recenterTriggered(int24 tick, int24 lower, int24 upper, uint16 thresholdBps) internal pure returns (bool) {
        if (tick < lower || tick >= upper) return true;
        // Compare in doubled units to avoid rounding the center: |2*tick - (lower+upper)| vs (upper-lower).
        int256 dist2 = 2 * int256(tick) - int256(lower) - int256(upper);
        if (dist2 < 0) dist2 = -dist2;
        return dist2 * 10_000 >= (int256(upper) - int256(lower)) * int256(uint256(thresholdBps));
    }

    /// @notice Converts an amount of token0 into token1 at `sqrtPriceX96` (rounded down).
    function toToken1(uint256 amount0, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96);
    }

    /// @notice Computes the swap that brings (`bal0`, `bal1`) to the token ratio required by the range
    ///         [`sqrtA`, `sqrtB`] at the current price `sqrtP`. Ignores pool fee and price impact; the
    ///         leftover after minting stays idle in the vault.
    /// @return zeroForOne Swap direction (true = sell token0).
    /// @return amountIn Exact input amount to sell (0 = no swap needed).
    function computeSwap(uint256 bal0, uint256 bal1, uint160 sqrtP, uint160 sqrtA, uint160 sqrtB)
        internal
        pure
        returns (bool zeroForOne, uint256 amountIn)
    {
        // Price below range: position is 100% token0, sell all token1.
        if (sqrtP <= sqrtA) return (false, bal1);
        // Price above range: position is 100% token1, sell all token0.
        if (sqrtP >= sqrtB) return (true, bal0);

        uint256 a0 = LiquidityAmounts.getAmount0ForLiquidity(sqrtP, sqrtB, REF_LIQUIDITY);
        uint256 a1 = LiquidityAmounts.getAmount1ForLiquidity(sqrtA, sqrtP, REF_LIQUIDITY);
        uint256 denom = toToken1(a0, sqrtP) + a1;
        if (denom == 0) return (false, 0);

        // Total value expressed in token1, split proportionally to the range composition.
        uint256 value1 = toToken1(bal0, sqrtP) + bal1;
        uint256 target0 = FullMath.mulDiv(value1, a0, denom);
        if (bal0 > target0) return (true, bal0 - target0);

        uint256 target1 = FullMath.mulDiv(value1, a1, denom);
        if (bal1 > target1) return (false, bal1 - target1);
        return (false, 0);
    }
}
