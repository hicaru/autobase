// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {AutoBaseVault} from "../src/AutoBaseVault.sol";

/// @dev Just enough pool surface for the constructor.
contract MockPool {
    address public token0 = address(0xA);
    address public token1 = address(0xB);
    int24 public tickSpacing = 60;
}

contract MockFactory {
    address public pool;

    constructor(address pool_) {
        pool = pool_;
    }

    function getPool(address, address, uint24) external view returns (address) {
        return pool;
    }
}

contract AutoBaseVaultAccessTest is Test {
    AutoBaseVault internal vault;
    IUniswapV3Factory internal factory;
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        factory = IUniswapV3Factory(address(new MockFactory(address(new MockPool()))));
        vault = new AutoBaseVault(keeper, factory, address(0xA), address(0xB), 3000, defaultParams());
    }

    function defaultParams() internal pure returns (AutoBaseVault.Params memory) {
        return AutoBaseVault.Params({
            halfWidthTicks: 600,
            twapWindow: 600,
            maxTwapDeviationTicks: 100,
            maxSlippageBps: 150,
            minRebalanceInterval: 1 hours,
            depositLock: 1 hours,
            minDepositValue: 1e4
        });
    }

    // ---------------- constructor ----------------

    function test_constructor_deployerIsOwnerAndPoolFixed() public view {
        assertEq(vault.owner(), address(this));
        assertEq(vault.keeper(), keeper);
        assertEq(address(vault.token0()), address(0xA));
        assertEq(address(vault.token1()), address(0xB));
        assertEq(vault.tickSpacing(), 60);
    }

    function test_constructor_revertsOnZeroKeeper() public {
        vm.expectRevert(AutoBaseVault.ZeroAddress.selector);
        new AutoBaseVault(address(0), factory, address(0xA), address(0xB), 3000, defaultParams());
    }

    function test_constructor_revertsOnUnknownPool() public {
        IUniswapV3Factory empty = IUniswapV3Factory(address(new MockFactory(address(0))));
        vm.expectRevert(AutoBaseVault.PoolNotFound.selector);
        new AutoBaseVault(keeper, empty, address(0xA), address(0xB), 3000, defaultParams());
    }

    function test_constructor_revertsOnInvalidParams() public {
        AutoBaseVault.Params memory p = defaultParams();
        p.maxSlippageBps = 0;
        vm.expectRevert(AutoBaseVault.InvalidParams.selector);
        new AutoBaseVault(keeper, factory, address(0xA), address(0xB), 3000, p);
    }

    // ---------------- owner-only ----------------

    function test_ownerFunctions_revertForKeeperAndAttacker() public {
        address[2] memory callers = [keeper, attacker];
        for (uint256 i; i < callers.length; ++i) {
            address c = callers[i];
            bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, c);

            vm.startPrank(c);
            vm.expectRevert(err);
            vault.setKeeper(c);
            vm.expectRevert(err);
            vault.setParams(defaultParams());
            vm.expectRevert(err);
            vault.pause();
            vm.expectRevert(err);
            vault.unpause();
            vm.expectRevert(err);
            vault.exitPosition();
            vm.expectRevert(err);
            vault.transferOwnership(c);
            vm.stopPrank();
        }
    }

    function test_ownership_isTwoStep() public {
        vault.transferOwnership(attacker);
        assertEq(vault.owner(), address(this));
        assertEq(vault.pendingOwner(), attacker);
        vm.prank(attacker);
        vault.acceptOwnership();
        assertEq(vault.owner(), attacker);
    }

    function test_setKeeper() public {
        address k = makeAddr("newKeeper");
        vault.setKeeper(k);
        assertEq(vault.keeper(), k);
    }

    function test_setKeeper_revertsOnZero() public {
        vm.expectRevert(AutoBaseVault.ZeroAddress.selector);
        vault.setKeeper(address(0));
    }

    // ---------------- params bounds ----------------

    function test_setParams_updatesMinDeposit() public {
        AutoBaseVault.Params memory p = defaultParams();
        p.minDepositValue = 5e6;
        vault.setParams(p);
        (,,,,,, uint128 minDeposit) = vault.params();
        assertEq(minDeposit, 5e6);
    }

    function test_renounceOwnership_disabled() public {
        vm.expectRevert(AutoBaseVault.RenounceDisabled.selector);
        vault.renounceOwnership();
        assertEq(vault.owner(), address(this));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vault.renounceOwnership();
    }

    function test_setParams_bounds() public {
        AutoBaseVault.Params memory p;

        p = defaultParams();
        p.halfWidthTicks = vault.MIN_HALF_WIDTH() - 1;
        _expectInvalid(p);
        p = defaultParams();
        p.halfWidthTicks = vault.MAX_HALF_WIDTH() + 1;
        _expectInvalid(p);
        p = defaultParams();
        p.twapWindow = vault.MIN_TWAP_WINDOW() - 1;
        _expectInvalid(p);
        p = defaultParams();
        p.twapWindow = vault.MAX_TWAP_WINDOW() + 1;
        _expectInvalid(p);
        p = defaultParams();
        p.maxTwapDeviationTicks = 0;
        _expectInvalid(p);
        p = defaultParams();
        p.maxTwapDeviationTicks = vault.MAX_TWAP_DEVIATION() + 1;
        _expectInvalid(p);
        p = defaultParams();
        p.maxSlippageBps = 0;
        _expectInvalid(p);
        p = defaultParams();
        p.maxSlippageBps = vault.MAX_SLIPPAGE_BPS() + 1;
        _expectInvalid(p);
        p = defaultParams();
        p.maxTwapDeviationTicks = int24(uint24(p.maxSlippageBps)); // deviation must be < slippage
        _expectInvalid(p);
        p = defaultParams();
        p.minRebalanceInterval = vault.MIN_REBALANCE_INTERVAL() - 1;
        _expectInvalid(p);
        p = defaultParams();
        p.minRebalanceInterval = vault.MAX_REBALANCE_INTERVAL() + 1;
        _expectInvalid(p);
        p = defaultParams();
        p.depositLock = vault.MIN_DEPOSIT_LOCK() - 1;
        _expectInvalid(p);
        p = defaultParams();
        p.depositLock = vault.MAX_DEPOSIT_LOCK() + 1;
        _expectInvalid(p);
        p = defaultParams();
        p.minDepositValue = vault.MIN_DEPOSIT_VALUE_FLOOR() - 1;
        _expectInvalid(p);
    }

    function _expectInvalid(AutoBaseVault.Params memory p) internal {
        vm.expectRevert(AutoBaseVault.InvalidParams.selector);
        vault.setParams(p);
    }

    // ---------------- keeper / users ----------------

    function test_rebalance_revertsForNonKeeper() public {
        vm.expectRevert(AutoBaseVault.NotKeeper.selector);
        vault.rebalance(0, block.timestamp);
        vm.prank(attacker);
        vm.expectRevert(AutoBaseVault.NotKeeper.selector);
        vault.rebalance(0, block.timestamp);
    }

    function test_rebalance_revertsWhenPaused() public {
        vault.pause();
        vm.prank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.rebalance(0, block.timestamp);
    }

    function test_deposit_revertsWhenPaused() public {
        vault.pause();
        vm.prank(attacker);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deposit(1, 1, 0, block.timestamp);
    }

    function test_deadlines() public {
        vm.warp(1000);
        vm.prank(keeper);
        vm.expectRevert(AutoBaseVault.Expired.selector);
        vault.rebalance(0, 999);
        vm.startPrank(attacker);
        vm.expectRevert(AutoBaseVault.Expired.selector);
        vault.deposit(1, 1, 0, 999);
        vm.expectRevert(AutoBaseVault.Expired.selector);
        vault.withdraw(1, 0, 0, 999);
        vm.stopPrank();
    }

    function test_zeroAmounts() public {
        vm.startPrank(attacker);
        vm.expectRevert(AutoBaseVault.ZeroAmount.selector);
        vault.deposit(0, 0, 0, block.timestamp);
        vm.expectRevert(AutoBaseVault.ZeroAmount.selector);
        vault.withdraw(0, 0, 0, block.timestamp);
        vm.stopPrank();
    }

    // ---------------- callbacks ----------------

    function test_callbacks_revertWhenNotInFlight() public {
        vm.startPrank(attacker);
        vm.expectRevert(AutoBaseVault.UnauthorizedCallback.selector);
        vault.uniswapV3MintCallback(1, 1, "");
        vm.expectRevert(AutoBaseVault.UnauthorizedCallback.selector);
        vault.uniswapV3SwapCallback(1, 1, "");
        vm.stopPrank();
    }

    function test_vault_rejectsEther() public {
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
    }
}
