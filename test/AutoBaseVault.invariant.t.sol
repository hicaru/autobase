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

/// @dev Drives random deposits, withdrawals, rebalances, market swaps and time jumps against the real pool.
contract VaultHandler is Test {
    using SafeERC20 for IERC20;

    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;

    AutoBaseVault public immutable vault;
    IUniswapV3Pool public immutable pool;
    address public immutable keeper;
    address[3] public users;

    /// @dev Set if a withdraw that should have succeeded reverted.
    bool public withdrawFailed;
    bytes public withdrawError;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public rebalances;
    bool internal inSwap;

    constructor(AutoBaseVault vault_, address keeper_) {
        vault = vault_;
        pool = vault_.pool();
        keeper = keeper_;
        users = [makeAddr("u0"), makeAddr("u1"), makeAddr("u2")];
        deal(WBTC, address(this), 1_000e8);
        deal(XAUT, address(this), 100_000e6);
    }

    function usersLength() external pure returns (uint256) {
        return 3;
    }

    function deposit(uint256 userSeed, uint256 a0, uint256 a1) external {
        address user = users[userSeed % 3];
        a0 = bound(a0, 0, 0.5e8);
        a1 = bound(a1, 0, 10e6);
        if (a0 == 0 && a1 == 0) return;
        deal(WBTC, user, a0);
        deal(XAUT, user, a1);
        vm.startPrank(user);
        IERC20(WBTC).forceApprove(address(vault), a0);
        IERC20(XAUT).forceApprove(address(vault), a1);
        // May legitimately revert: TWAP deviation after a market move, or below min deposit.
        try vault.deposit(a0, a1, 0, block.timestamp) {
            ++deposits;
        } catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 userSeed, uint256 pct) external {
        address user = users[userSeed % 3];
        uint256 bal = vault.balanceOf(user);
        if (bal == 0 || block.timestamp < vault.lockedUntil(user)) return;
        uint256 shares = bal * bound(pct, 1, 100) / 100;
        if (shares == 0) return;
        vm.prank(user);
        // Must never revert for an unlocked holder.
        try vault.withdraw(shares, 0, 0, block.timestamp) {
            ++withdrawals;
        } catch (bytes memory err) {
            withdrawFailed = true;
            withdrawError = err;
        }
    }

    function rebalance() external {
        vm.prank(keeper);
        try vault.rebalance(0, block.timestamp) {
            ++rebalances;
        } catch {}
    }

    function marketSwap(int24 ticks) external {
        ticks = int24(bound(ticks, -150, 150));
        (, int24 tick,,,,,) = pool.slot0();
        int24 target = tick + ticks;
        if (target == tick) return;
        inSwap = true;
        pool.swap(address(this), target < tick, type(int128).max, TickMath.getSqrtRatioAtTick(target), "");
        inSwap = false;
    }

    function skipTime(uint256 secs) external {
        secs = bound(secs, 12, 2 hours);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 12);
    }

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        require(inSwap && msg.sender == address(pool), "cb");
        if (d0 > 0) IERC20(WBTC).safeTransfer(msg.sender, SafeCast.toUint256(d0));
        if (d1 > 0) IERC20(XAUT).safeTransfer(msg.sender, SafeCast.toUint256(d1));
    }
}

/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = false
contract AutoBaseVaultInvariantTest is Test {
    IUniswapV3Factory internal constant FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;

    AutoBaseVault internal vault;
    VaultHandler internal handler;
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 26_220_000);

        vault = new AutoBaseVault(
            keeper,
            FACTORY,
            WBTC,
            XAUT,
            3000,
            AutoBaseVault.Params({
                halfWidthTicks: 600,
                twapWindow: 600,
                maxTwapDeviationTicks: 100,
                maxSlippageBps: 150,
                minRebalanceInterval: 1 hours,
                depositLock: 10 minutes, // short lock so withdrawals get exercised
                minDepositValue: 1e4
            })
        );
        handler = new VaultHandler(vault, keeper);
        targetContract(address(handler));
    }

    function invariant_withdrawNeverFails() public view {
        assertFalse(handler.withdrawFailed(), string(handler.withdrawError()));
    }

    function invariant_supplyIsDeadPlusUsers() public view {
        uint256 sum = vault.balanceOf(address(0xdEaD));
        for (uint256 i; i < handler.usersLength(); ++i) {
            sum += vault.balanceOf(handler.users(i));
        }
        assertEq(vault.totalSupply(), sum);
    }

    function invariant_privilegedRolesHoldNothing() public view {
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.balanceOf(keeper), 0);
        assertEq(IERC20(WBTC).balanceOf(keeper), 0);
        assertEq(IERC20(XAUT).balanceOf(keeper), 0);
        assertEq(IERC20(WBTC).allowance(address(vault), address(vault.pool())), 0);
        assertEq(IERC20(XAUT).allowance(address(vault), address(vault.pool())), 0);
    }

    /// @dev At the end of every run, every holder can fully exit and only dead-share dust stays behind.
    function afterInvariant() public {
        emit log_named_uint("deposits", handler.deposits());
        emit log_named_uint("withdrawals", handler.withdrawals());
        emit log_named_uint("rebalances", handler.rebalances());
        vm.warp(block.timestamp + 1 days);
        for (uint256 i; i < handler.usersLength(); ++i) {
            address user = handler.users(i);
            uint256 bal = vault.balanceOf(user);
            if (bal == 0) continue;
            vm.prank(user);
            vault.withdraw(bal, 0, 0, block.timestamp);
            assertEq(vault.balanceOf(user), 0);
        }
        uint256 supply = vault.totalSupply();
        assertTrue(supply == 0 || supply == vault.DEAD_SHARES());
    }
}
