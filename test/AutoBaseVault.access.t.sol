// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import {AutoBaseVault} from "../src/AutoBaseVault.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 1e24);
    }
}

/// @dev Factory that knows no pools.
contract EmptyFactory {
    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

contract AutoBaseVaultAccessTest is Test {
    AutoBaseVault internal vault;
    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        vault = new AutoBaseVault(owner, keeper, IUniswapV3Factory(address(new EmptyFactory())), defaultParams());
    }

    function defaultParams() internal pure returns (AutoBaseVault.Params memory) {
        return AutoBaseVault.Params({
            halfWidthTicks: 600,
            twapWindow: 600,
            maxTwapDeviationTicks: 100,
            maxSlippageBps: 150,
            minRebalanceInterval: 1 hours
        });
    }

    // ---------------- constructor ----------------

    function test_constructor_revertsOnZeroKeeper() public {
        IUniswapV3Factory f = IUniswapV3Factory(address(new EmptyFactory()));
        vm.expectRevert(AutoBaseVault.ZeroAddress.selector);
        new AutoBaseVault(owner, address(0), f, defaultParams());
    }

    function test_constructor_revertsOnZeroOwner() public {
        IUniswapV3Factory f = IUniswapV3Factory(address(new EmptyFactory()));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AutoBaseVault(address(0), keeper, f, defaultParams());
    }

    // ---------------- owner-only ----------------

    function test_ownerFunctions_revertForKeeperAndAttacker() public {
        address[2] memory callers = [keeper, attacker];
        for (uint256 i; i < callers.length; ++i) {
            address c = callers[i];
            bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, c);

            vm.startPrank(c);
            vm.expectRevert(err);
            vault.setPool(address(1), address(2), 3000);
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
            vault.withdraw(IERC20(address(1)), 1);
            vm.stopPrank();
        }
    }

    function test_ownership_isTwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(attacker);
        assertEq(vault.owner(), owner);
        assertEq(vault.pendingOwner(), attacker);
        vm.prank(attacker);
        vault.acceptOwnership();
        assertEq(vault.owner(), attacker);
    }

    function test_setKeeper() public {
        address k = makeAddr("newKeeper");
        vm.prank(owner);
        vault.setKeeper(k);
        assertEq(vault.keeper(), k);
    }

    function test_setKeeper_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(AutoBaseVault.ZeroAddress.selector);
        vault.setKeeper(address(0));
    }

    function test_setPool_revertsWhenUnknown() public {
        vm.prank(owner);
        vm.expectRevert(AutoBaseVault.PoolNotFound.selector);
        vault.setPool(address(1), address(2), 3000);
    }

    // ---------------- params bounds ----------------

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
    }

    function _expectInvalid(AutoBaseVault.Params memory p) internal {
        vm.prank(owner);
        vm.expectRevert(AutoBaseVault.InvalidParams.selector);
        vault.setParams(p);
    }

    // ---------------- keeper ----------------

    function test_rebalance_revertsForNonKeeper() public {
        vm.prank(owner);
        vm.expectRevert(AutoBaseVault.NotKeeper.selector);
        vault.rebalance(0, block.timestamp);
        vm.prank(attacker);
        vm.expectRevert(AutoBaseVault.NotKeeper.selector);
        vault.rebalance(0, block.timestamp);
    }

    function test_rebalance_revertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.rebalance(0, block.timestamp);
    }

    function test_rebalance_revertsAfterDeadline() public {
        vm.warp(1000);
        vm.prank(keeper);
        vm.expectRevert(AutoBaseVault.Expired.selector);
        vault.rebalance(0, 999);
    }

    function test_rebalance_revertsWithoutPool() public {
        vm.prank(keeper);
        vm.expectRevert(AutoBaseVault.PoolNotSet.selector);
        vault.rebalance(0, block.timestamp);
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

    // ---------------- withdraw ----------------

    function test_withdraw_alwaysGoesToOwner() public {
        MockToken t = new MockToken();
        assertTrue(t.transfer(address(vault), 100));
        vm.prank(owner);
        vault.withdraw(t, 60);
        assertEq(t.balanceOf(owner), 60);
        assertEq(t.balanceOf(address(vault)), 40);
    }

    function test_vault_rejectsEther() public {
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
    }
}
