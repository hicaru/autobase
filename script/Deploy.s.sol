// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {AutoBaseVault} from "../src/AutoBaseVault.sol";

/// @notice Deploys the vault. The broadcaster (deployer) becomes the owner; the pool is fixed at deploy.
/// @dev Dry-run:  forge script script/Deploy.s.sol --fork-url $ETH_RPC_URL --sender <deployer>
///      Live:     forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --account <keystore> --broadcast --verify
contract Deploy is Script {
    IUniswapV3Factory internal constant FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    function run() external returns (AutoBaseVault vault) {
        address keeper = vm.envAddress("KEEPER");
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        uint24 fee = uint24(vm.envUint("POOL_FEE"));
        uint128 minDepositValue = uint128(vm.envUint("MIN_DEPOSIT_VALUE"));
        require(keeper != msg.sender, "keeper == owner");

        AutoBaseVault.Params memory params = AutoBaseVault.Params({
            halfWidthTicks: 600,
            twapWindow: 600,
            maxTwapDeviationTicks: 100,
            maxSlippageBps: 150,
            minRebalanceInterval: 1 hours,
            depositLock: 1 hours,
            minDepositValue: minDepositValue
        });

        vm.startBroadcast();
        vault = new AutoBaseVault(keeper, FACTORY, tokenA, tokenB, fee, params);
        vm.stopBroadcast();

        console.log("AutoBaseVault:", address(vault));
        console.log("Pool:", address(vault.pool()));
        console.log("Owner:", vault.owner());
    }
}
