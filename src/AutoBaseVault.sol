// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3MintCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

import {RebalanceMath} from "./libraries/RebalanceMath.sol";

/// @title AutoBaseVault
/// @notice Public Uniswap v3 LP vault for a single pool. Users deposit token0 and/or token1 and receive ERC20
///         shares; deposits sit idle until the keeper bot calls `rebalance()`, which re-centers the range
///         around the current price and deploys all idle funds. Withdrawals are pro-rata in both tokens and
///         are never blocked by pause.
/// @dev Roles: owner (deployer) sets keeper/params and can pause; keeper can only call `rebalance()`;
///      nobody but a share holder can move funds out of the vault.
contract AutoBaseVault is
    ERC20,
    Ownable2Step,
    Pausable,
    ReentrancyGuardTransient,
    IUniswapV3MintCallback,
    IUniswapV3SwapCallback
{
    using SafeERC20 for IERC20;

    struct Params {
        /// @dev Half range width in ticks (~1 bp per tick).
        int24 halfWidthTicks;
        /// @dev TWAP window in seconds used as the reference price.
        uint32 twapWindow;
        /// @dev Max allowed |spot tick - TWAP tick| for rebalance and deposit.
        int24 maxTwapDeviationTicks;
        /// @dev Max loss vs. TWAP quote on the rebalance swap, pool fee included.
        uint16 maxSlippageBps;
        /// @dev Cooldown between range moves.
        uint32 minRebalanceInterval;
    }

    uint256 internal constant BPS = 10_000;
    int24 public constant MIN_HALF_WIDTH = 10;
    int24 public constant MAX_HALF_WIDTH = 100_000;
    uint32 public constant MIN_TWAP_WINDOW = 60;
    uint32 public constant MAX_TWAP_WINDOW = 1 hours;
    int24 public constant MAX_TWAP_DEVIATION = 1_000;
    uint16 public constant MAX_SLIPPAGE_BPS = 500;
    uint32 public constant MIN_REBALANCE_INTERVAL = 1 minutes;
    uint32 public constant MAX_REBALANCE_INTERVAL = 7 days;
    /// @dev Shares minted per unit of first-deposit value (value is in token1 base units).
    uint256 public constant INITIAL_SHARES_PER_UNIT = 1e6;
    /// @dev Shares burned to a dead address on first deposit (inflation-attack mitigation).
    uint256 public constant DEAD_SHARES = 1e9;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @dev Wei kept back from each balance when sizing liquidity: pool.mint rounds owed amounts up.
    uint256 internal constant MINT_DUST = 2;
    /// @dev Rebalance swaps whose TWAP-quoted output is below this many base units are skipped: integer
    ///      rounding on dust would trip the slippage check. Assumes both tokens have >= 6 decimals.
    uint256 internal constant MIN_SWAP_OUT = 1_000;

    IUniswapV3Pool public immutable pool;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    int24 public immutable tickSpacing;

    address public keeper;
    Params public params;

    int24 public tickLower;
    int24 public tickUpper;
    uint256 public lastRebalance;

    /// @dev Set only while this contract is inside a pool.mint / pool.swap call it initiated.
    bool private transient _expectingCallback;

    event KeeperSet(address indexed keeper);
    event ParamsSet(Params params);
    event Deposited(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdrawn(address indexed user, uint256 shares, uint256 amount0, uint256 amount1);
    event Rebalanced(
        int24 oldLower,
        int24 oldUpper,
        int24 newLower,
        int24 newUpper,
        uint128 liquidityAdded,
        uint256 fees0,
        uint256 fees1
    );
    event Swapped(bool zeroForOne, uint256 amountIn, uint256 amountOut);
    event PositionExited(int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1);

    error ZeroAddress();
    error ZeroAmount();
    error NotKeeper();
    error PoolNotFound();
    error InvalidParams();
    error Expired();
    error Cooldown();
    error TwapDeviation(int24 spotTick, int24 twapTick);
    error NothingToDo();
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error InsufficientLiquidity(uint128 liquidity, uint128 minLiquidity);
    error InsufficientShares(uint256 shares, uint256 minShares);
    error InsufficientOutput(uint256 amount0, uint256 amount1);
    error DepositTooSmall();
    error UnauthorizedCallback();

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /// @notice The deployer becomes the owner. The pool is fixed for the lifetime of the vault.
    constructor(
        address keeper_,
        IUniswapV3Factory factory,
        address tokenA,
        address tokenB,
        uint24 fee,
        Params memory params_
    ) ERC20("AutoBase LP", "ABLP") Ownable(msg.sender) {
        if (keeper_ == address(0) || address(factory) == address(0)) revert ZeroAddress();
        address p = factory.getPool(tokenA, tokenB, fee);
        if (p == address(0)) revert PoolNotFound();

        pool = IUniswapV3Pool(p);
        token0 = IERC20(IUniswapV3Pool(p).token0());
        token1 = IERC20(IUniswapV3Pool(p).token1());
        tickSpacing = IUniswapV3Pool(p).tickSpacing();
        _setKeeper(keeper_);
        _setParams(params_);
    }

    // ------------------------------------------------------------------
    // Owner
    // ------------------------------------------------------------------

    function setKeeper(address keeper_) external onlyOwner {
        _setKeeper(keeper_);
    }

    function setParams(Params calldata params_) external onlyOwner {
        _setParams(params_);
    }

    /// @notice Stops deposits and rebalances. Withdrawals keep working.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Emergency: burns the whole position into idle balances inside the vault (funds never leave).
    function exitPosition() external onlyOwner nonReentrant {
        int24 lower = tickLower;
        int24 upper = tickUpper;
        if (_positionLiquidity() == 0) revert NothingToDo();
        (uint256 amount0, uint256 amount1,,) = _burnAndCollect(lower, upper);
        tickLower = 0;
        tickUpper = 0;
        emit PositionExited(lower, upper, amount0, amount1);
    }

    // ------------------------------------------------------------------
    // Users
    // ------------------------------------------------------------------

    /// @notice Deposits token0 and/or token1 (requires prior `approve`) and mints shares to the caller.
    ///         Funds stay idle until the next `rebalance()`.
    /// @dev Shares are priced at both spot and TWAP and the depositor gets the lower amount, so moving the
    ///      pool price can only hurt the depositor, never existing holders.
    function deposit(uint256 amount0, uint256 amount1, uint256 minShares, uint256 deadline)
        external
        whenNotPaused
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 shares)
    {
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();
        (uint160 sqrtSpot, uint160 sqrtTwap) = _checkedPrices();
        _collectFees();

        // Vault holdings before the deposit, valued at both prices.
        uint128 liquidity = _positionLiquidity();
        uint256 valueSpot = _totalValue(sqrtSpot, liquidity);
        uint256 valueTwap = _totalValue(sqrtTwap, liquidity);

        uint256 received0 = _pull(token0, amount0);
        uint256 received1 = _pull(token1, amount1);
        uint256 depSpot = RebalanceMath.toToken1(received0, sqrtSpot) + received1;
        uint256 depTwap = RebalanceMath.toToken1(received0, sqrtTwap) + received1;

        uint256 supply = totalSupply();
        if (supply == 0) {
            shares = (depSpot < depTwap ? depSpot : depTwap) * INITIAL_SHARES_PER_UNIT;
            if (shares <= DEAD_SHARES) revert DepositTooSmall();
            _mint(DEAD, DEAD_SHARES);
            shares -= DEAD_SHARES;
        } else {
            if (valueSpot == 0 || valueTwap == 0) revert DepositTooSmall();
            uint256 atSpot = FullMath.mulDiv(depSpot, supply, valueSpot);
            uint256 atTwap = FullMath.mulDiv(depTwap, supply, valueTwap);
            shares = atSpot < atTwap ? atSpot : atTwap;
        }
        if (shares == 0 || shares < minShares) revert InsufficientShares(shares, minShares);

        _mint(msg.sender, shares);
        emit Deposited(msg.sender, received0, received1, shares);
    }

    /// @notice Burns `shares` and sends the caller its pro-rata part of idle funds, fees and the position.
    ///         Works while paused. No swap, so the share math cannot be manipulated via the pool price;
    ///         `min0`/`min1` protect the caller's token mix against sandwiching.
    function withdraw(uint256 shares, uint256 min0, uint256 min1, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        _burn(msg.sender, shares);

        _collectFees();
        amount0 = FullMath.mulDiv(token0.balanceOf(address(this)), shares, supply);
        amount1 = FullMath.mulDiv(token1.balanceOf(address(this)), shares, supply);

        uint128 burnLiquidity = SafeCast.toUint128(FullMath.mulDiv(_positionLiquidity(), shares, supply));
        if (burnLiquidity != 0) {
            (uint256 burned0, uint256 burned1) = pool.burn(tickLower, tickUpper, burnLiquidity);
            pool.collect(address(this), tickLower, tickUpper, SafeCast.toUint128(burned0), SafeCast.toUint128(burned1));
            amount0 += burned0;
            amount1 += burned1;
        }
        if (amount0 < min0 || amount1 < min1) revert InsufficientOutput(amount0, amount1);

        if (amount0 != 0) token0.safeTransfer(msg.sender, amount0);
        if (amount1 != 0) token1.safeTransfer(msg.sender, amount1);
        emit Withdrawn(msg.sender, shares, amount0, amount1);
    }

    // ------------------------------------------------------------------
    // Keeper
    // ------------------------------------------------------------------

    /// @notice Re-centers the position around the current price if the range changed (subject to cooldown),
    ///         otherwise compounds fees and idle deposits into the current range.
    /// @param minLiquidity Keeper-side floor on the liquidity added by this call.
    /// @param deadline Transaction is rejected after this timestamp.
    function rebalance(uint128 minLiquidity, uint256 deadline)
        external
        onlyKeeper
        whenNotPaused
        nonReentrant
        checkDeadline(deadline)
    {
        Params memory cfg = params;
        (, int24 spotTick,,,,,) = pool.slot0();
        int24 twapTick = _twapTick(cfg.twapWindow);
        _checkDeviation(spotTick, twapTick, cfg.maxTwapDeviationTicks);

        (int24 newLower, int24 newUpper) = RebalanceMath.rangeAround(spotTick, cfg.halfWidthTicks, tickSpacing);
        int24 oldLower = tickLower;
        int24 oldUpper = tickUpper;
        uint128 liquidity = _positionLiquidity();
        bool moveRange = liquidity == 0 || newLower != oldLower || newUpper != oldUpper;

        uint256 fees0;
        uint256 fees1;
        if (moveRange) {
            if (lastRebalance != 0 && block.timestamp < lastRebalance + cfg.minRebalanceInterval) revert Cooldown();
            // Effects before interactions with the pool.
            lastRebalance = block.timestamp;
            tickLower = newLower;
            tickUpper = newUpper;
            if (liquidity != 0) (,, fees0, fees1) = _burnAndCollect(oldLower, oldUpper);
        } else {
            newLower = oldLower;
            newUpper = oldUpper;
            (fees0, fees1) = _collectFees();
        }

        _swapToRatio(twapTick, cfg.maxSlippageBps, newLower, newUpper);
        uint128 added = _mint(newLower, newUpper);
        if (added == 0 && !moveRange) revert NothingToDo();
        if (added == 0 || added < minLiquidity) revert InsufficientLiquidity(added, minLiquidity);

        emit Rebalanced(oldLower, oldUpper, newLower, newUpper, added, fees0, fees1);
    }

    // ------------------------------------------------------------------
    // Uniswap callbacks
    // ------------------------------------------------------------------

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external override {
        _checkCallback();
        if (amount0Owed != 0) token0.safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed != 0) token1.safeTransfer(msg.sender, amount1Owed);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        _checkCallback();
        if (amount0Delta > 0) token0.safeTransfer(msg.sender, SafeCast.toUint256(amount0Delta));
        if (amount1Delta > 0) token1.safeTransfer(msg.sender, SafeCast.toUint256(amount1Delta));
    }

    // ------------------------------------------------------------------
    // Views (informational only — spot-based, never use as an oracle)
    // ------------------------------------------------------------------

    function positionLiquidity() external view returns (uint128) {
        return _positionLiquidity();
    }

    /// @notice Idle + position amounts at the current spot price, excluding uncollected fees.
    function totalAmounts() external view returns (uint256 total0, uint256 total1) {
        (uint160 sqrtSpot,,,,,,) = pool.slot0();
        return _totalAmounts(sqrtSpot, _positionLiquidity());
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _setKeeper(address keeper_) internal {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function _setParams(Params memory p) internal {
        if (
            p.halfWidthTicks < MIN_HALF_WIDTH || p.halfWidthTicks > MAX_HALF_WIDTH || p.twapWindow < MIN_TWAP_WINDOW
                || p.twapWindow > MAX_TWAP_WINDOW || p.maxTwapDeviationTicks <= 0
                || p.maxTwapDeviationTicks > MAX_TWAP_DEVIATION || p.maxSlippageBps == 0
                || p.maxSlippageBps > MAX_SLIPPAGE_BPS
                // Swap price limit (TWAP +/- slippage) must stay beyond any allowed spot price.
                || int256(p.maxTwapDeviationTicks) >= int256(uint256(p.maxSlippageBps))
                || p.minRebalanceInterval < MIN_REBALANCE_INTERVAL || p.minRebalanceInterval > MAX_REBALANCE_INTERVAL
        ) revert InvalidParams();
        params = p;
        emit ParamsSet(p);
    }

    function _checkCallback() internal view {
        if (!_expectingCallback || msg.sender != address(pool)) revert UnauthorizedCallback();
    }

    function _checkDeviation(int24 spotTick, int24 twapTick, int24 maxDeviation) internal pure {
        int24 deviation = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
        if (deviation > maxDeviation) revert TwapDeviation(spotTick, twapTick);
    }

    /// @dev Spot and TWAP sqrt prices, reverting if they diverge more than allowed.
    function _checkedPrices() internal view returns (uint160 sqrtSpot, uint160 sqrtTwap) {
        Params memory cfg = params;
        int24 spotTick;
        (sqrtSpot, spotTick,,,,,) = pool.slot0();
        int24 twapTick = _twapTick(cfg.twapWindow);
        _checkDeviation(spotTick, twapTick, cfg.maxTwapDeviationTicks);
        sqrtTwap = TickMath.getSqrtRatioAtTick(twapTick);
    }

    function _twapTick(uint32 window) internal view returns (int24 tick) {
        (tick,) = OracleLibrary.consult(address(pool), window);
    }

    function _positionLiquidity() internal view returns (uint128 liquidity) {
        (liquidity,,,,) = pool.positions(keccak256(abi.encodePacked(address(this), tickLower, tickUpper)));
    }

    function _totalAmounts(uint160 sqrtP, uint128 liquidity) internal view returns (uint256 total0, uint256 total1) {
        if (liquidity != 0) {
            (total0, total1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtP, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
            );
        }
        total0 += token0.balanceOf(address(this));
        total1 += token1.balanceOf(address(this));
    }

    /// @dev Total vault value in token1 units at `sqrtP`.
    function _totalValue(uint160 sqrtP, uint128 liquidity) internal view returns (uint256) {
        (uint256 total0, uint256 total1) = _totalAmounts(sqrtP, liquidity);
        return RebalanceMath.toToken1(total0, sqrtP) + total1;
    }

    /// @dev Pulls `amount` from the caller and returns what actually arrived.
    function _pull(IERC20 token, uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        return token.balanceOf(address(this)) - before;
    }

    /// @dev Moves accrued fees of the current position into idle balances.
    function _collectFees() internal returns (uint256 fees0, uint256 fees1) {
        if (_positionLiquidity() == 0) return (0, 0);
        pool.burn(tickLower, tickUpper, 0);
        (uint128 c0, uint128 c1) =
            pool.collect(address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max);
        return (c0, c1);
    }

    /// @return collected0 Total token0 received (principal + fees).
    /// @return collected1 Total token1 received (principal + fees).
    /// @return fees0 Fees part of token0.
    /// @return fees1 Fees part of token1.
    function _burnAndCollect(int24 lower, int24 upper)
        internal
        returns (uint256 collected0, uint256 collected1, uint256 fees0, uint256 fees1)
    {
        (uint128 liquidity,,,,) = pool.positions(keccak256(abi.encodePacked(address(this), lower, upper)));
        (uint256 burned0, uint256 burned1) = pool.burn(lower, upper, liquidity);
        (uint128 c0, uint128 c1) = pool.collect(address(this), lower, upper, type(uint128).max, type(uint128).max);
        collected0 = c0;
        collected1 = c1;
        fees0 = collected0 - burned0;
        fees1 = collected1 - burned1;
    }

    function _swapToRatio(int24 twapTick, uint16 slippageBps, int24 lower, int24 upper) internal {
        (uint160 sqrtP,,,,,,) = pool.slot0();
        (bool zeroForOne, uint256 amountIn) = RebalanceMath.computeSwap(
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this)),
            sqrtP,
            TickMath.getSqrtRatioAtTick(lower),
            TickMath.getSqrtRatioAtTick(upper)
        );
        if (amountIn == 0 || _quoteAtTwap(zeroForOne, amountIn, twapTick) < MIN_SWAP_OUT) return;
        _swapGuarded(zeroForOne, amountIn, twapTick, slippageBps);
    }

    /// @dev Swaps `amountIn` with a hard price limit and a min-out both derived from the TWAP, never from spot.
    function _swapGuarded(bool zeroForOne, uint256 amountIn, int24 twapTick, uint16 slippageBps) internal {
        // ~1 tick per bp.
        int24 limitTick = zeroForOne ? twapTick - int24(uint24(slippageBps)) : twapTick + int24(uint24(slippageBps));
        if (limitTick <= TickMath.MIN_TICK) limitTick = TickMath.MIN_TICK + 1;
        if (limitTick >= TickMath.MAX_TICK) limitTick = TickMath.MAX_TICK - 1;

        _expectingCallback = true;
        (int256 d0, int256 d1) = pool.swap(
            address(this), zeroForOne, SafeCast.toInt256(amountIn), TickMath.getSqrtRatioAtTick(limitTick), ""
        );
        _expectingCallback = false;

        // The limit may cause a partial fill; check what was actually paid vs. what was received.
        (uint256 paid, uint256 received) = zeroForOne
            ? (SafeCast.toUint256(d0), SafeCast.toUint256(-d1))
            : (SafeCast.toUint256(d1), SafeCast.toUint256(-d0));
        uint256 minOut = FullMath.mulDiv(_quoteAtTwap(zeroForOne, paid, twapTick), BPS - slippageBps, BPS);
        if (received < minOut) revert SlippageExceeded(received, minOut);

        emit Swapped(zeroForOne, paid, received);
    }

    function _quoteAtTwap(bool zeroForOne, uint256 amountIn, int24 twapTick) internal view returns (uint256) {
        return zeroForOne
            ? OracleLibrary.getQuoteAtTick(twapTick, SafeCast.toUint128(amountIn), address(token0), address(token1))
            : OracleLibrary.getQuoteAtTick(twapTick, SafeCast.toUint128(amountIn), address(token1), address(token0));
    }

    function _mint(int24 lower, int24 upper) internal returns (uint128 liquidity) {
        (uint160 sqrtP,,,,,,) = pool.slot0();
        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtRatioAtTick(lower),
            TickMath.getSqrtRatioAtTick(upper),
            bal0 > MINT_DUST ? bal0 - MINT_DUST : 0,
            bal1 > MINT_DUST ? bal1 - MINT_DUST : 0
        );
        if (liquidity == 0) return 0;

        _expectingCallback = true;
        pool.mint(address(this), lower, upper, liquidity, "");
        _expectingCallback = false;
    }
}
