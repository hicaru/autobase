// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
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
/// @notice Single-owner vault holding one Uniswap v3 concentrated-liquidity position. A keeper bot calls
///         `rebalance()` to re-center the range around the current price. The keeper can never move funds
///         out of the vault, change parameters, or trade at a price far from the pool TWAP.
contract AutoBaseVault is
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
        /// @dev Max allowed |spot tick - TWAP tick| to rebalance at all.
        int24 maxTwapDeviationTicks;
        /// @dev Max loss vs. TWAP quote on the rebalance swap, pool fee included.
        uint16 maxSlippageBps;
        /// @dev Cooldown between rebalances.
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
    /// @dev Wei kept back from each balance when sizing liquidity: pool.mint rounds owed amounts up.
    uint256 internal constant MINT_DUST = 2;

    IUniswapV3Factory public immutable factory;

    IUniswapV3Pool public pool;
    IERC20 public token0;
    IERC20 public token1;
    int24 public tickSpacing;

    address public keeper;
    Params public params;

    int24 public tickLower;
    int24 public tickUpper;
    uint256 public lastRebalance;

    /// @dev Set only while this contract is inside a pool.mint / pool.swap call it initiated.
    bool private transient _expectingCallback;

    event PoolSet(address indexed pool, address token0, address token1, uint24 fee, int24 tickSpacing);
    event KeeperSet(address indexed keeper);
    event ParamsSet(Params params);
    event Rebalanced(
        int24 oldLower, int24 oldUpper, int24 newLower, int24 newUpper, uint128 liquidity, uint256 fees0, uint256 fees1
    );
    event Swapped(bool zeroForOne, uint256 amountIn, uint256 amountOut);
    event PositionExited(int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1);
    event Withdrawn(address indexed token, uint256 amount);

    error ZeroAddress();
    error NotKeeper();
    error PoolNotSet();
    error PoolNotFound();
    error PositionOpen();
    error InvalidParams();
    error Expired();
    error Cooldown();
    error TwapDeviation(int24 spotTick, int24 twapTick);
    error NothingToDo();
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error InsufficientLiquidity(uint128 liquidity, uint128 minLiquidity);
    error UnauthorizedCallback();

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    constructor(address owner_, address keeper_, IUniswapV3Factory factory_, Params memory params_) Ownable(owner_) {
        if (keeper_ == address(0) || address(factory_) == address(0)) revert ZeroAddress();
        factory = factory_;
        _setKeeper(keeper_);
        _setParams(params_);
    }

    // ------------------------------------------------------------------
    // Owner
    // ------------------------------------------------------------------

    /// @notice Selects the pool by (tokenA, tokenB, fee) via the canonical factory. Only while no position is open.
    function setPool(address tokenA, address tokenB, uint24 fee) external onlyOwner {
        if (_positionLiquidity() != 0) revert PositionOpen();
        address p = factory.getPool(tokenA, tokenB, fee);
        if (p == address(0)) revert PoolNotFound();

        IUniswapV3Pool newPool = IUniswapV3Pool(p);
        pool = newPool;
        token0 = IERC20(newPool.token0());
        token1 = IERC20(newPool.token1());
        tickSpacing = newPool.tickSpacing();
        tickLower = 0;
        tickUpper = 0;
        emit PoolSet(p, address(token0), address(token1), fee, tickSpacing);
    }

    function setKeeper(address keeper_) external onlyOwner {
        _setKeeper(keeper_);
    }

    function setParams(Params calldata params_) external onlyOwner {
        _setParams(params_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Burns the whole position and collects everything into the vault.
    function exitPosition() external onlyOwner nonReentrant {
        int24 lower = tickLower;
        int24 upper = tickUpper;
        (uint256 amount0, uint256 amount1,,) = _burnAndCollect();
        tickLower = 0;
        tickUpper = 0;
        emit PositionExited(lower, upper, amount0, amount1);
    }

    /// @notice Sends `amount` of `token` to the owner. Funds can only ever leave to the owner.
    function withdraw(IERC20 token, uint256 amount) external onlyOwner nonReentrant {
        token.safeTransfer(owner(), amount);
        emit Withdrawn(address(token), amount);
    }

    // ------------------------------------------------------------------
    // Keeper
    // ------------------------------------------------------------------

    /// @notice Re-centers the position around the current price.
    /// @param minLiquidity Keeper-side floor on the minted liquidity.
    /// @param deadline Transaction is rejected after this timestamp.
    function rebalance(uint128 minLiquidity, uint256 deadline) external onlyKeeper whenNotPaused nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        IUniswapV3Pool p = pool;
        if (address(p) == address(0)) revert PoolNotSet();
        Params memory cfg = params;
        if (lastRebalance != 0 && block.timestamp < lastRebalance + cfg.minRebalanceInterval) revert Cooldown();

        (, int24 spotTick,,,,,) = p.slot0();
        int24 twapTick = _twapTick(p, cfg.twapWindow);
        int24 deviation = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
        if (deviation > cfg.maxTwapDeviationTicks) revert TwapDeviation(spotTick, twapTick);

        (int24 newLower, int24 newUpper) = RebalanceMath.rangeAround(spotTick, cfg.halfWidthTicks, tickSpacing);
        int24 oldLower = tickLower;
        int24 oldUpper = tickUpper;
        bool hasPosition = _positionLiquidity() != 0;
        if (hasPosition && newLower == oldLower && newUpper == oldUpper) revert NothingToDo();

        // Effects before interactions with the pool.
        lastRebalance = block.timestamp;
        tickLower = newLower;
        tickUpper = newUpper;

        uint256 fees0;
        uint256 fees1;
        if (hasPosition) {
            (,, fees0, fees1) = _burnAndCollect(oldLower, oldUpper);
        }

        _swapToRatio(p, twapTick, cfg.maxSlippageBps, newLower, newUpper);
        uint128 liquidity = _mint(p, newLower, newUpper);
        if (liquidity == 0 || liquidity < minLiquidity) revert InsufficientLiquidity(liquidity, minLiquidity);

        emit Rebalanced(oldLower, oldUpper, newLower, newUpper, liquidity, fees0, fees1);
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
    // Views
    // ------------------------------------------------------------------

    function positionLiquidity() external view returns (uint128) {
        return _positionLiquidity();
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

    function _positionLiquidity() internal view returns (uint128 liquidity) {
        IUniswapV3Pool p = pool;
        if (address(p) == address(0)) return 0;
        (liquidity,,,,) = p.positions(keccak256(abi.encodePacked(address(this), tickLower, tickUpper)));
    }

    function _twapTick(IUniswapV3Pool p, uint32 window) internal view returns (int24 tick) {
        (tick,) = OracleLibrary.consult(address(p), window);
    }

    function _burnAndCollect() internal returns (uint256, uint256, uint256, uint256) {
        if (_positionLiquidity() == 0) revert NothingToDo();
        return _burnAndCollect(tickLower, tickUpper);
    }

    /// @return collected0 Total token0 received (principal + fees).
    /// @return collected1 Total token1 received (principal + fees).
    /// @return fees0 Fees part of token0.
    /// @return fees1 Fees part of token1.
    function _burnAndCollect(int24 lower, int24 upper)
        internal
        returns (uint256 collected0, uint256 collected1, uint256 fees0, uint256 fees1)
    {
        IUniswapV3Pool p = pool;
        (uint128 liquidity,,,,) = p.positions(keccak256(abi.encodePacked(address(this), lower, upper)));
        (uint256 burned0, uint256 burned1) = p.burn(lower, upper, liquidity);
        (uint128 c0, uint128 c1) = p.collect(address(this), lower, upper, type(uint128).max, type(uint128).max);
        collected0 = c0;
        collected1 = c1;
        fees0 = collected0 - burned0;
        fees1 = collected1 - burned1;
    }

    function _swapToRatio(IUniswapV3Pool p, int24 twapTick, uint16 slippageBps, int24 lower, int24 upper) internal {
        (uint160 sqrtP,,,,,,) = p.slot0();
        (bool zeroForOne, uint256 amountIn) = RebalanceMath.computeSwap(
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this)),
            sqrtP,
            TickMath.getSqrtRatioAtTick(lower),
            TickMath.getSqrtRatioAtTick(upper)
        );
        if (amountIn == 0) return;
        _swapGuarded(p, zeroForOne, amountIn, twapTick, slippageBps);
    }

    /// @dev Swaps `amountIn` with a hard price limit and a min-out both derived from the TWAP, never from spot.
    function _swapGuarded(IUniswapV3Pool p, bool zeroForOne, uint256 amountIn, int24 twapTick, uint16 slippageBps)
        internal
    {
        // ~1 tick per bp.
        int24 limitTick = zeroForOne ? twapTick - int24(uint24(slippageBps)) : twapTick + int24(uint24(slippageBps));
        if (limitTick <= TickMath.MIN_TICK) limitTick = TickMath.MIN_TICK + 1;
        if (limitTick >= TickMath.MAX_TICK) limitTick = TickMath.MAX_TICK - 1;

        _expectingCallback = true;
        (int256 d0, int256 d1) =
            p.swap(address(this), zeroForOne, SafeCast.toInt256(amountIn), TickMath.getSqrtRatioAtTick(limitTick), "");
        _expectingCallback = false;

        // The limit may cause a partial fill; check what was actually paid vs. what was received.
        (uint256 paid, uint256 received) = zeroForOne
            ? (SafeCast.toUint256(d0), SafeCast.toUint256(-d1))
            : (SafeCast.toUint256(d1), SafeCast.toUint256(-d0));
        uint256 quote = zeroForOne
            ? OracleLibrary.getQuoteAtTick(twapTick, SafeCast.toUint128(paid), address(token0), address(token1))
            : OracleLibrary.getQuoteAtTick(twapTick, SafeCast.toUint128(paid), address(token1), address(token0));
        uint256 minOut = FullMath.mulDiv(quote, BPS - slippageBps, BPS);
        if (received < minOut) revert SlippageExceeded(received, minOut);

        emit Swapped(zeroForOne, paid, received);
    }

    function _mint(IUniswapV3Pool p, int24 lower, int24 upper) internal returns (uint128 liquidity) {
        (uint160 sqrtP,,,,,,) = p.slot0();
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
        p.mint(address(this), lower, upper, liquidity, "");
        _expectingCallback = false;
    }
}
