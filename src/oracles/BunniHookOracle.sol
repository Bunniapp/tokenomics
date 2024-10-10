// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {Ownable} from "solady/auth/Ownable.sol";
import {SSTORE2} from "solady/utils/SSTORE2.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import "../external/IBunniHook.sol";
import {TickMath} from "../lib/TickMath.sol";
import {IOracle} from "../interfaces/IOracle.sol";

/// @title Oracle using BunniHook TWAP oracle as data source
/// @author zefram.eth
/// @notice The oracle contract that provides the current price to purchase
/// the underlying token while exercising options. Uses BunniHook TWAP oracle
/// as data source, and then applies a multiplier & lower bound.
contract BunniHookOracle is IOracle, Ownable {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SSTORE2 for *;
    using TickMath for *;
    using FixedPointMathLib for *;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error BunniHookOracle__InvalidPoolKey();

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event SetParams(uint16 multiplier, uint32 secs, uint32 ago, uint128 minPrice);
    event SetPoolKey(PoolKey poolKey);

    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    /// @notice The denominator for converting the multiplier into a decimal number.
    /// i.e. multiplier uses 4 decimals.
    uint256 internal constant MULTIPLIER_DENOM = 10000;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    /// @notice The BunniHook contract
    IBunniHook public immutable bunniHook;

    /// @inheritdoc IOracle
    address public immutable paymentToken;

    /// @inheritdoc IOracle
    address public immutable underlyingToken;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    /// @notice The multiplier applied to the TWAP value. Encodes the discount of
    /// the options token. Uses 4 decimals.
    uint16 public multiplier;

    /// @notice The size of the window to take the TWAP value over in seconds.
    uint32 public secs;

    /// @notice The number of seconds in the past to take the TWAP from. The window
    /// would be (block.timestamp - secs - ago, block.timestamp - ago].
    uint32 public ago;

    /// @notice The minimum value returned by getPrice(). Maintains a floor for the
    /// price to mitigate potential attacks on the TWAP oracle.
    uint128 public minPrice;

    /// @notice The SSTORE2 pointer to the PoolKey used to query the BunniHook TWAP oracle.
    address public poolKeyPointer;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(
        IBunniHook bunniHook_,
        PoolKey memory poolKey,
        address paymentToken_,
        address underlyingToken_,
        address owner_,
        uint16 multiplier_,
        uint32 secs_,
        uint32 ago_,
        uint128 minPrice_
    ) {
        bunniHook = bunniHook_;
        paymentToken = paymentToken_;
        underlyingToken = underlyingToken_;

        multiplier = multiplier_;
        secs = secs_;
        ago = ago_;
        minPrice = minPrice_;

        emit SetParams(multiplier_, secs_, ago_, minPrice_);

        _initializeOwner(owner_);

        if (
            !(
                (poolKey.currency0 == paymentToken_ && poolKey.currency1 == underlyingToken_)
                    || (poolKey.currency0 == underlyingToken_ && poolKey.currency1 == paymentToken_)
            ) || poolKey.hooks != address(bunniHook_)
        ) {
            revert BunniHookOracle__InvalidPoolKey();
        }
        poolKeyPointer = abi.encode(poolKey).write();
        emit SetPoolKey(poolKey);
    }

    /// -----------------------------------------------------------------------
    /// IOracle
    /// -----------------------------------------------------------------------

    /// @inheritdoc IOracle
    function getPrice() external view override returns (uint256 price) {
        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        uint16 multiplier_ = multiplier;
        uint32 secs_ = secs;
        uint32 ago_ = ago;
        uint256 minPrice_ = minPrice;

        /// -----------------------------------------------------------------------
        /// Computation
        /// -----------------------------------------------------------------------

        // query BunniHook to get TWAP value
        {
            // get average tick
            PoolKey memory poolKey = getPoolKey();
            int24 arithmeticMeanTick = _queryTwap(poolKey, secs_ + ago_, ago_);

            // the unit of the average price is (currency1 / currency0)
            // if paymentToken is not currency1 of the pool, negate the tick
            // so that the unit of the average price is (paymentToken / underlyingToken)
            arithmeticMeanTick = paymentToken == poolKey.currency1 ? arithmeticMeanTick : -arithmeticMeanTick;

            // convert tick to sqrtPriceX96
            uint256 sqrtPriceX96 = arithmeticMeanTick.getSqrtPriceAtTick();

            // convert sqrtPriceX96 in Q96 (2**96) to price in WAD (1e18)
            // mulDiv cannot overflow since log2(MAX_SQRT_PRICE * WAD) ~= 219.79 < 256
            uint256 sqrtPriceWad = sqrtPriceX96.mulDiv(WAD, Q96);

            // compute the price by squaring the sqrtPriceWad
            // mulWad cannot overflow since log2((MAX_SQRT_PRICE * WAD / Q96)**2) ~= 247.94 < 256
            price = sqrtPriceWad.mulWad(sqrtPriceWad);
        }

        // apply multiplier to price
        price = price.mulDivUp(multiplier_, MULTIPLIER_DENOM);

        // bound price above minPrice
        price = FixedPointMathLib.max(price, minPrice_);
    }

    /// -----------------------------------------------------------------------
    /// Getters
    /// -----------------------------------------------------------------------

    /// @notice Returns the pool key used to query the BunniHook TWAP oracle.
    function getPoolKey() public view returns (PoolKey memory) {
        return abi.decode(poolKeyPointer.read(), (PoolKey));
    }

    /// -----------------------------------------------------------------------
    /// Owner functions
    /// -----------------------------------------------------------------------

    /// @notice Updates the oracle parameters. Only callable by the owner.
    /// @param multiplier_ The multiplier applied to the TWAP value. Encodes the discount of
    /// the options token. Uses 4 decimals.
    /// @param secs_ The size of the window to take the TWAP value over in seconds.
    /// @param ago_ The number of seconds in the past to take the TWAP from. The window
    /// would be (block.timestamp - secs - ago, block.timestamp - ago].
    /// @param minPrice_ The minimum value returned by getPrice(). Maintains a floor for the
    /// price to mitigate potential attacks on the TWAP oracle.
    function setParams(uint16 multiplier_, uint32 secs_, uint32 ago_, uint128 minPrice_) external onlyOwner {
        multiplier = multiplier_;
        secs = secs_;
        ago = ago_;
        minPrice = minPrice_;
        emit SetParams(multiplier_, secs_, ago_, minPrice_);
    }

    /// @notice Sets the pool key used to query the BunniHook TWAP oracle.
    /// Only callable by the owner.
    /// @param poolKey The new pool key
    function setPoolKey(PoolKey calldata poolKey) external onlyOwner {
        // validate pool key
        if (
            !(
                (poolKey.currency0 == paymentToken && poolKey.currency1 == underlyingToken)
                    || (poolKey.currency0 == underlyingToken && poolKey.currency1 == paymentToken)
            ) || poolKey.hooks != address(bunniHook)
        ) {
            revert BunniHookOracle__InvalidPoolKey();
        }

        poolKeyPointer = abi.encode(poolKey).write();
        emit SetPoolKey(poolKey);
    }

    /// -----------------------------------------------------------------------
    /// Internal utilities
    /// -----------------------------------------------------------------------

    /// @dev Computes the arithmetic mean tick of the TWAP window.
    /// The TWAP window is defined by (block.timestamp - twapSecondsAgoStart, block.timestamp - twapSecondsAgoEnd].
    /// The window size is (twapSecondsAgoStart - twapSecondsAgoEnd).
    /// The unit of the average price is (currency1 / currency0).
    function _queryTwap(PoolKey memory poolKey, uint32 twapSecondsAgoStart, uint32 twapSecondsAgoEnd)
        internal
        view
        returns (int24 arithmeticMeanTick)
    {
        uint32 windowSize = twapSecondsAgoStart - twapSecondsAgoEnd;
        IBunniHook hook = IBunniHook(address(poolKey.hooks));
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapSecondsAgoStart;
        secondsAgos[1] = twapSecondsAgoEnd;
        int56[] memory tickCumulatives = hook.observe(poolKey, secondsAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        return int24(tickCumulativesDelta / int56(uint56(windowSize)));
    }
}
