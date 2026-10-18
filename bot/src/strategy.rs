//! Pure decision logic: volatility → range width, re-center trigger (mirrors the contract), and whether
//! to act this round. No I/O here so everything is unit-testable.

use serde::Serialize;

/// ln(1.0001): one Uniswap tick in log-price units.
pub const LN_TICK: f64 = 0.000_099_995_000_333_308_33;

/// Daily realized volatility (stdev of log returns, scaled to 1 day) from `(timestamp_secs, tick)` samples
/// sorted by time. Returns `None` with fewer than 24 usable returns.
pub fn realized_vol_daily(samples: &[(i64, i32)]) -> Option<f64> {
    let rets: Vec<(f64, f64)> = samples
        .windows(2)
        .filter_map(|w| {
            let dt = (w[1].0 - w[0].0) as f64;
            (dt > 0.0).then(|| ((w[1].1 - w[0].1) as f64 * LN_TICK, dt))
        })
        .collect();
    if rets.len() < 24 {
        return None;
    }
    let n = rets.len() as f64;
    let mean_dt = rets.iter().map(|r| r.1).sum::<f64>() / n;
    let mean = rets.iter().map(|r| r.0).sum::<f64>() / n;
    let var = rets.iter().map(|r| (r.0 - mean).powi(2)).sum::<f64>() / (n - 1.0);
    let per_day = 86_400.0 / mean_dt;
    Some((var * per_day).sqrt())
}

/// Half width in ticks so the price is expected to stay in range for `target_days`:
/// `σ_daily · √days`, converted to ticks, rounded up to `spacing`, clamped to `[min, max]`.
/// Without volatility data the widest allowed range is used (cheapest, fewest rebalances).
pub fn choose_half_width(sigma_daily: Option<f64>, target_days: f64, min: i32, max: i32, spacing: i32) -> i32 {
    let Some(sigma) = sigma_daily.filter(|s| s.is_finite() && *s > 0.0) else {
        return max;
    };
    let ticks = (sigma * target_days.max(0.0).sqrt() / LN_TICK).ceil();
    let ticks = if ticks > i32::MAX as f64 {
        i32::MAX
    } else {
        ticks as i32
    };
    let spacing = spacing.max(1);
    // Round up to a multiple of `spacing` (ticks is non-negative here).
    let aligned = ((ticks + spacing - 1) / spacing).saturating_mul(spacing);
    aligned.clamp(min, max)
}

/// Mirror of `RebalanceMath.recenterTriggered`.
pub fn recenter_triggered(tick: i32, lower: i32, upper: i32, threshold_bps: u16) -> bool {
    if tick < lower || tick >= upper {
        return true;
    }
    let dist2 = (2 * tick as i64 - lower as i64 - upper as i64).abs();
    dist2 * 10_000 >= (upper as i64 - lower as i64) * threshold_bps as i64
}

/// Everything the decision needs, read from chain by the caller.
#[derive(Debug, Clone, Serialize)]
pub struct DecisionInput {
    pub paused: bool,
    pub has_position: bool,
    pub tick: i32,
    pub twap_tick: i32,
    pub max_twap_deviation: i32,
    pub tick_lower: i32,
    pub tick_upper: i32,
    pub recenter_threshold_bps: u16,
    pub now: u64,
    pub last_rebalance: u64,
    pub min_rebalance_interval: u64,
    /// Idle vault balance valued in token1 base units.
    pub idle_value: f64,
    pub compound_min_value: f64,
    pub base_fee_gwei: f64,
    pub max_base_fee_gwei: f64,
    /// Seconds the position has been out of range (0 when in range).
    pub out_of_range_secs: u64,
    pub max_out_of_range_secs: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "action", content = "reason", rename_all = "snake_case")]
pub enum Decision {
    Skip(&'static str),
    Recenter,
    Compound,
}

pub fn decide(i: &DecisionInput) -> Decision {
    if i.paused {
        return Decision::Skip("paused");
    }
    if (i.tick - i.twap_tick).abs() > i.max_twap_deviation {
        // The contract would revert with TwapDeviation.
        return Decision::Skip("spot deviates from twap");
    }
    let has_idle = i.idle_value >= i.compound_min_value;
    let wants_recenter = if i.has_position {
        recenter_triggered(i.tick, i.tick_lower, i.tick_upper, i.recenter_threshold_bps)
    } else {
        i.idle_value > 0.0
    };
    if !wants_recenter && !has_idle {
        return Decision::Skip(if i.has_position || i.idle_value > 0.0 {
            "nothing to do"
        } else {
            "empty vault"
        });
    }

    let cooldown_over = i.last_rebalance == 0 || i.now >= i.last_rebalance + i.min_rebalance_interval;
    let gas_ok = i.base_fee_gwei <= i.max_base_fee_gwei
        || (wants_recenter && i.has_position && i.out_of_range_secs >= i.max_out_of_range_secs);
    if !gas_ok {
        return Decision::Skip("gas too expensive");
    }
    if wants_recenter && cooldown_over {
        return Decision::Recenter;
    }
    if i.has_position && has_idle {
        // The contract compounds into the current range while the cooldown runs.
        return if wants_recenter {
            Decision::Skip("cooldown")
        } else {
            Decision::Compound
        };
    }
    Decision::Skip("cooldown")
}

/// Price of token0 in token1 base units from a Q64.96 sqrt price.
pub fn price_from_sqrt_x96(sqrt_price_x96: f64) -> f64 {
    let s = sqrt_price_x96 / 2f64.powi(96);
    s * s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input() -> DecisionInput {
        DecisionInput {
            paused: false,
            has_position: true,
            tick: 0,
            twap_tick: 0,
            max_twap_deviation: 100,
            tick_lower: -600,
            tick_upper: 600,
            recenter_threshold_bps: 8000,
            now: 10_000,
            last_rebalance: 1,
            min_rebalance_interval: 3600,
            idle_value: 0.0,
            compound_min_value: 1000.0,
            base_fee_gwei: 1.0,
            max_base_fee_gwei: 30.0,
            out_of_range_secs: 0,
            max_out_of_range_secs: 7200,
        }
    }

    #[test]
    fn trigger_matches_contract_cases() {
        // Same cases as RebalanceMathTest.test_recenterTriggered.
        assert!(!recenter_triggered(0, -600, 600, 8000));
        assert!(!recenter_triggered(479, -600, 600, 8000));
        assert!(recenter_triggered(480, -600, 600, 8000));
        assert!(!recenter_triggered(-479, -600, 600, 8000));
        assert!(recenter_triggered(-480, -600, 600, 8000));
        assert!(recenter_triggered(600, -600, 600, 8000));
        assert!(recenter_triggered(-601, -600, 600, 8000));
        assert!(!recenter_triggered(599, -600, 600, 10_000));
    }

    #[test]
    fn vol_from_constant_price_is_zero_and_needs_data() {
        let flat: Vec<_> = (0..48).map(|h| (h * 3600, -16_000)).collect();
        assert_eq!(realized_vol_daily(&flat), Some(0.0));
        assert_eq!(realized_vol_daily(&flat[..10]), None);
    }

    #[test]
    fn vol_scales_to_daily() {
        // Alternating ±100 ticks every hour: hourly log-return stdev ≈ 100*LN_TICK*k, daily = hourly*√24.
        let s: Vec<_> = (0..200).map(|h| (h * 3600, if h % 2 == 0 { 0 } else { 100 })).collect();
        let v = realized_vol_daily(&s).unwrap();
        let hourly = 100.0 * LN_TICK;
        assert!((v - hourly * 24f64.sqrt()).abs() / v < 0.02, "v={v}");
    }

    #[test]
    fn width_aligned_and_clamped() {
        // σ = 1.68%/day, 20 days → ~7.5% → ~751 ticks → 780 aligned to 60.
        assert_eq!(choose_half_width(Some(0.0168), 20.0, 420, 1800, 60), 780);
        assert_eq!(choose_half_width(Some(0.0001), 20.0, 420, 1800, 60), 420);
        assert_eq!(choose_half_width(Some(1.0), 20.0, 420, 1800, 60), 1800);
        assert_eq!(choose_half_width(None, 20.0, 420, 1800, 60), 1800);
        assert_eq!(choose_half_width(Some(f64::NAN), 20.0, 420, 1800, 60), 1800);
    }

    #[test]
    fn decide_paths() {
        let mut i = input();
        assert_eq!(decide(&i), Decision::Skip("nothing to do"));

        i.idle_value = 5000.0;
        assert_eq!(decide(&i), Decision::Compound);

        i.tick = 500; // past 80%
        i.twap_tick = 500;
        assert_eq!(decide(&i), Decision::Recenter);

        i.last_rebalance = i.now - 10; // cooldown running, trigger met
        assert_eq!(decide(&i), Decision::Skip("cooldown"));

        let mut i = input();
        i.paused = true;
        assert_eq!(decide(&i), Decision::Skip("paused"));

        let mut i = input();
        i.twap_tick = 101;
        assert_eq!(decide(&i), Decision::Skip("spot deviates from twap"));
    }

    #[test]
    fn decide_first_deposit_and_empty() {
        let mut i = input();
        i.has_position = false;
        assert_eq!(decide(&i), Decision::Skip("empty vault"));
        i.idle_value = 1.0;
        assert_eq!(decide(&i), Decision::Recenter);
    }

    #[test]
    fn gas_cap_overridden_only_when_out_of_range_long() {
        let mut i = input();
        i.base_fee_gwei = 100.0;
        i.tick = 700; // out of range
        i.twap_tick = 700;
        i.out_of_range_secs = 60;
        assert_eq!(decide(&i), Decision::Skip("gas too expensive"));
        i.out_of_range_secs = 7200;
        assert_eq!(decide(&i), Decision::Recenter);
        // Compounding is never worth expensive gas.
        let mut i = input();
        i.base_fee_gwei = 100.0;
        i.idle_value = 5000.0;
        assert_eq!(decide(&i), Decision::Skip("gas too expensive"));
    }

    #[test]
    fn price_from_sqrt() {
        assert!((price_from_sqrt_x96(2f64.powi(96)) - 1.0).abs() < 1e-12);
    }
}
