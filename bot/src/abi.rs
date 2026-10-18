//! Minimal Solidity interfaces the bot talks to. Kept in sync with `src/AutoBaseVault.sol` by the
//! `abi_matches_forge_artifact` test, which compares selectors against the forge build output.

// Generated constructors for 8-field events exceed clippy's argument limit; the code is macro output.
#![allow(clippy::too_many_arguments)]

use alloy::sol;

sol! {
    #[derive(Debug)]
    interface IAutoBaseVault {
        struct Params {
            int24 minHalfWidthTicks;
            int24 maxHalfWidthTicks;
            uint16 recenterThresholdBps;
            uint32 twapWindow;
            int24 maxTwapDeviationTicks;
            uint16 maxSlippageBps;
            uint32 minRebalanceInterval;
            uint32 depositLock;
            uint128 minDepositValue;
        }

        function params() external view returns (
            int24 minHalfWidthTicks,
            int24 maxHalfWidthTicks,
            uint16 recenterThresholdBps,
            uint32 twapWindow,
            int24 maxTwapDeviationTicks,
            uint16 maxSlippageBps,
            uint32 minRebalanceInterval,
            uint32 depositLock,
            uint128 minDepositValue
        );
        function keeper() external view returns (address);
        function pool() external view returns (address);
        function token0() external view returns (address);
        function token1() external view returns (address);
        function tickSpacing() external view returns (int24);
        function tickLower() external view returns (int24);
        function tickUpper() external view returns (int24);
        function lastRebalance() external view returns (uint256);
        function paused() external view returns (bool);
        function positionLiquidity() external view returns (uint128);
        function totalSupply() external view returns (uint256);
        function totalAmounts() external view returns (uint256 total0, uint256 total1);
        function rebalance(int24 halfWidthTicks, uint128 minLiquidity, uint256 deadline) external returns (uint128 added);

        event Deposited(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);
        event Withdrawn(address indexed user, uint256 shares, uint256 amount0, uint256 amount1);
        event Rebalanced(
            int24 oldLower,
            int24 oldUpper,
            int24 newLower,
            int24 newUpper,
            int24 halfWidthTicks,
            uint128 liquidityAdded,
            uint256 fees0,
            uint256 fees1
        );
        event Swapped(bool zeroForOne, uint256 amountIn, uint256 amountOut);
        event PositionExited(int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1);
        event ParamsSet(Params params);
        event KeeperSet(address indexed keeper);

        error NotKeeper();
        error InvalidWidth();
        error Expired();
        error Cooldown();
        error TwapDeviation(int24 spotTick, int24 twapTick);
        error NothingToDo();
        error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
        error InsufficientLiquidity(uint128 liquidity, uint128 minLiquidity);
        error EnforcedPause();
    }

    #[derive(Debug)]
    interface IUniswapV3Pool {
        function slot0() external view returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
        function observe(uint32[] secondsAgos) external view returns (
            int56[] tickCumulatives,
            uint160[] secondsPerLiquidityCumulativeX128s
        );
        function feeGrowthGlobal0X128() external view returns (uint256);
        function feeGrowthGlobal1X128() external view returns (uint256);
        function ticks(int24 tick) external view returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );
        function positions(bytes32 key) external view returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
    }

    #[derive(Debug)]
    interface IERC20 {
        function balanceOf(address account) external view returns (uint256);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::json_abi::JsonAbi;
    use alloy::sol_types::{SolCall, SolEvent};

    /// Fails if the inline interface drifts from the compiled contract. Skips when `forge build` hasn't run.
    #[test]
    fn abi_matches_forge_artifact() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../out/AutoBaseVault.sol/AutoBaseVault.json"
        );
        let Ok(raw) = std::fs::read_to_string(path) else {
            eprintln!("skipping: {path} not found (run `forge build`)");
            return;
        };
        let artifact: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let abi: JsonAbi = serde_json::from_value(artifact["abi"].clone()).unwrap();

        let selectors: Vec<[u8; 4]> = abi.functions().map(|f| f.selector().0).collect();
        for (name, sel) in [
            ("params", IAutoBaseVault::paramsCall::SELECTOR),
            ("keeper", IAutoBaseVault::keeperCall::SELECTOR),
            ("pool", IAutoBaseVault::poolCall::SELECTOR),
            ("tickLower", IAutoBaseVault::tickLowerCall::SELECTOR),
            ("tickUpper", IAutoBaseVault::tickUpperCall::SELECTOR),
            ("lastRebalance", IAutoBaseVault::lastRebalanceCall::SELECTOR),
            ("paused", IAutoBaseVault::pausedCall::SELECTOR),
            ("positionLiquidity", IAutoBaseVault::positionLiquidityCall::SELECTOR),
            ("rebalance", IAutoBaseVault::rebalanceCall::SELECTOR),
        ] {
            assert!(selectors.contains(&sel), "function {name} not in compiled ABI");
        }

        let events: Vec<_> = abi.events().map(|e| e.selector()).collect();
        for (name, topic) in [
            ("Deposited", IAutoBaseVault::Deposited::SIGNATURE_HASH),
            ("Withdrawn", IAutoBaseVault::Withdrawn::SIGNATURE_HASH),
            ("Rebalanced", IAutoBaseVault::Rebalanced::SIGNATURE_HASH),
            ("Swapped", IAutoBaseVault::Swapped::SIGNATURE_HASH),
            ("PositionExited", IAutoBaseVault::PositionExited::SIGNATURE_HASH),
            ("ParamsSet", IAutoBaseVault::ParamsSet::SIGNATURE_HASH),
        ] {
            assert!(events.contains(&topic), "event {name} not in compiled ABI");
        }

        // Output arity of params() must match the struct (9 fields).
        let params_fn = abi.functions().find(|f| f.name == "params").unwrap();
        assert_eq!(params_fn.outputs.len(), 9);
    }
}
