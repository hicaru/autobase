//! Uniswap v3 fee accounting (port of `Tick.getFeeGrowthInside` and `Position.update`), all in
//! wrapping 256-bit arithmetic exactly like the pool.

use alloy::primitives::U256;

/// Pool state needed for one token's fee growth.
#[derive(Debug, Clone, Copy)]
pub struct FeeGrowth {
    pub global: U256,
    pub outside_lower: U256,
    pub outside_upper: U256,
}

/// Fee growth inside `[lower, upper)` per unit of liquidity (Q128), wrapping.
pub fn fee_growth_inside(tick: i32, lower: i32, upper: i32, g: FeeGrowth) -> U256 {
    let below = if tick >= lower {
        g.outside_lower
    } else {
        g.global.wrapping_sub(g.outside_lower)
    };
    let above = if tick < upper {
        g.outside_upper
    } else {
        g.global.wrapping_sub(g.outside_upper)
    };
    g.global.wrapping_sub(below).wrapping_sub(above)
}

/// `liquidity * delta / 2^128`, truncated like `FullMath.mulDiv(delta, liquidity, Q128)` cast to uint128.
pub fn fees_for(liquidity: u128, inside_now: U256, inside_last: U256) -> U256 {
    let delta = inside_now.wrapping_sub(inside_last);
    let l = U256::from(liquidity);
    let lo = delta & U256::from(u128::MAX);
    let hi = delta >> 128usize;
    // (hi·2^128 + lo)·L / 2^128 = hi·L + (lo·L >> 128); both products fit in 256 bits.
    let low = (lo * l) >> 128usize;
    let total = hi.wrapping_mul(l).wrapping_add(low);
    total & U256::from(u128::MAX)
}

/// Uncollected fees of a position: owed + newly accrued since its last checkpoint.
pub fn pending_fees(owed: u128, liquidity: u128, inside_now: U256, inside_last: U256) -> U256 {
    U256::from(owed) + fees_for(liquidity, inside_now, inside_last)
}

#[cfg(test)]
mod tests {
    use super::*;

    const Q128: U256 = U256::from_limbs([0, 0, 1, 0]);

    fn g(global: u64, lo: u64, up: u64) -> FeeGrowth {
        FeeGrowth {
            global: U256::from(global),
            outside_lower: U256::from(lo),
            outside_upper: U256::from(up),
        }
    }

    #[test]
    fn inside_when_price_in_range() {
        // below = outside_lower, above = outside_upper.
        assert_eq!(fee_growth_inside(0, -10, 10, g(100, 30, 20)), U256::from(50));
    }

    #[test]
    fn inside_when_price_below_or_above() {
        // tick < lower: below = global - outside_lower.
        assert_eq!(
            fee_growth_inside(-20, -10, 10, g(100, 30, 20)),
            U256::from(100 - 70 - 20)
        );
        // tick >= upper: above = global - outside_upper.
        // above = 100 - 20 = 80; inside = 100 - 30 - 80 wraps below zero, exactly like Solidity.
        let expected = U256::from(100u64).wrapping_sub(U256::from(110u64));
        assert_eq!(fee_growth_inside(10, -10, 10, g(100, 30, 20)), expected);
    }

    #[test]
    fn inside_wraps_like_solidity() {
        // Underflow is expected and must wrap, not panic.
        let v = fee_growth_inside(0, -10, 10, g(10, 30, 20));
        assert_eq!(v, U256::from(10u64).wrapping_sub(U256::from(50u64)));
    }

    #[test]
    fn fees_one_unit_per_liquidity() {
        // delta = 1.0 (Q128) → fees = liquidity.
        assert_eq!(fees_for(1_000_000, Q128, U256::ZERO), U256::from(1_000_000u64));
        // delta = 0.5 → half.
        assert_eq!(fees_for(1_000_000, Q128 >> 1usize, U256::ZERO), U256::from(500_000u64));
        // Wrapped checkpoint: last > now.
        let last = U256::MAX - Q128 + U256::from(1u8);
        assert_eq!(fees_for(10, U256::ZERO, last), U256::from(10u8));
    }

    #[test]
    fn pending_adds_owed() {
        assert_eq!(pending_fees(7, 1_000, Q128, U256::ZERO), U256::from(1_007u64));
    }
}
