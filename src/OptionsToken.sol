// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {LibMulticaller} from "multicaller/LibMulticaller.sol";

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {XERC20} from "./lib/XERC20.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {ReentrancyGuard} from "./lib/ReentrancyGuard.sol";

/// @title Options Token
/// @author zefram.eth
/// @notice Options token representing the right to purchase the underlying token
/// at an oracle-specified rate. Similar to call options but with a variable strike
/// price that's always at a certain discount to the market price.
/// @dev Assumes the underlying token and the payment token both use 18 decimals.
contract OptionsToken is XERC20, ReentrancyGuard {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeTransferLib for *;
    using FixedPointMathLib for *;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error OptionsToken__InvalidLength();
    error OptionsToken__PastDeadline();
    error OptionsToken__InvalidOracle();
    error OptionsToken__SlippageTooHigh();
    error OptionsToken__InvalidTokenDecimals();

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event Exercise(address indexed sender, address indexed recipient, uint256 amount, uint256 paymentAmount);
    event SetOracle(IOracle indexed newOracle);
    event SetTreasury(address indexed newTreasury);

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    /// @notice The token paid by the options token holder during redemption. Set to
    /// address(0) if the payment token is ETH.
    address public immutable paymentToken;

    /// @notice The underlying token purchased during redemption
    address public immutable underlyingToken;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    /// @notice The oracle contract that provides the current price to purchase
    /// the underlying token while exercising options (the strike price)
    IOracle public oracle;

    /// @notice The treasury address which receives tokens paid during redemption
    address public treasury;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(
        address owner_,
        IOracle oracle_,
        address treasury_,
        uint256[] memory _minterLimits,
        uint256[] memory _burnerLimits,
        address[] memory _bridges
    ) XERC20(owner_) {
        paymentToken = oracle_.paymentToken();
        underlyingToken = oracle_.underlyingToken();

        // validate token decimals
        if (
            (paymentToken != address(0) && ERC20(paymentToken).decimals() != 18)
                || ERC20(underlyingToken).decimals() != 18
        ) {
            revert OptionsToken__InvalidTokenDecimals();
        }

        oracle = oracle_;
        treasury = treasury_;

        emit SetOracle(oracle_);
        emit SetTreasury(treasury_);

        uint256 _bridgesLength = _bridges.length;
        if (_minterLimits.length != _bridgesLength || _burnerLimits.length != _bridgesLength) {
            revert OptionsToken__InvalidLength();
        }

        for (uint256 i; i < _bridgesLength; ++i) {
            _setLimits(_bridges[i], _minterLimits[i], _burnerLimits[i]);
        }
    }

    /// -----------------------------------------------------------------------
    /// External functions
    /// -----------------------------------------------------------------------

    /// @notice Mints options tokens by taking underlying tokens from the sender.
    /// @param to The address that will receive the minted options tokens
    /// @param amount The amount of options tokens that will be minted
    function mintOptions(address to, uint256 amount) external nonReentrant {
        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // skip if amount is zero
        if (amount == 0) return;

        // mint options tokens
        _mint(to, amount);

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        address msgSender = LibMulticaller.senderOrSigner();

        // transfer underlying tokens from msgSender to this contract
        underlyingToken.safeTransferFrom2(msgSender, address(this), amount);
    }

    /// @notice Exercises options tokens to purchase the underlying tokens.
    /// The oracle may revert if it cannot give a secure result.
    /// @param amount The amount of options tokens to exercise
    /// @param maxPaymentAmount The maximum acceptable amount to pay. Used for slippage protection.
    /// @param recipient The recipient of the purchased underlying tokens
    /// @return paymentAmount The amount paid to the treasury to purchase the underlying tokens
    function exercise(uint256 amount, uint256 maxPaymentAmount, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 paymentAmount)
    {
        return _exercise(amount, maxPaymentAmount, recipient);
    }

    /// @notice Exercises options tokens to purchase the underlying tokens.
    /// The oracle may revert if it cannot give a secure result.
    /// @param amount The amount of options tokens to exercise
    /// @param maxPaymentAmount The maximum acceptable amount to pay. Used for slippage protection.
    /// @param recipient The recipient of the purchased underlying tokens
    /// @param deadline The Unix timestamp (in seconds) after which the call will revert
    /// @return paymentAmount The amount paid to the treasury to purchase the underlying tokens
    function exercise(uint256 amount, uint256 maxPaymentAmount, address recipient, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 paymentAmount)
    {
        if (block.timestamp > deadline) revert OptionsToken__PastDeadline();
        return _exercise(amount, maxPaymentAmount, recipient);
    }

    /// -----------------------------------------------------------------------
    /// Getters
    /// -----------------------------------------------------------------------

    function name() public pure override returns (string memory) {
        return "Bunni Call Option Token";
    }

    function symbol() public pure override returns (string memory) {
        return "oBUNNI";
    }

    /// -----------------------------------------------------------------------
    /// Owner functions
    /// -----------------------------------------------------------------------

    /// @notice Sets the oracle contract. Only callable by the owner.
    /// @param oracle_ The new oracle contract
    function setOracle(IOracle oracle_) external onlyOwner {
        // ensure the new oracle has the same underlying token and payment token
        if (oracle_.underlyingToken() != underlyingToken || oracle_.paymentToken() != paymentToken) {
            revert OptionsToken__InvalidOracle();
        }

        oracle = oracle_;
        emit SetOracle(oracle_);
    }

    /// @notice Sets the treasury address. Only callable by the owner.
    /// @param treasury_ The new treasury address
    function setTreasury(address treasury_) external onlyOwner {
        treasury = treasury_;
        emit SetTreasury(treasury_);
    }

    /// -----------------------------------------------------------------------
    /// Internal functions
    /// -----------------------------------------------------------------------

    function _exercise(uint256 amount, uint256 maxPaymentAmount, address recipient)
        internal
        virtual
        returns (uint256 paymentAmount)
    {
        // skip if amount is zero
        if (amount == 0) return 0;

        // burn options tokens from msgSender
        // will revert if msgSender doesn't have enough options tokens
        address msgSender = LibMulticaller.senderOrSigner();
        _burn(msgSender, amount);

        // compute payment amount
        paymentAmount = amount.mulWadUp(oracle.getPrice());
        if (paymentAmount > maxPaymentAmount) revert OptionsToken__SlippageTooHigh();

        // transfer payment tokens from msgSender to the treasury
        if (paymentToken == address(0)) {
            // ETH transfer
            treasury.safeTransferETH(paymentAmount);

            // refund msgSender
            uint256 refund = msg.value - paymentAmount;
            if (refund != 0) {
                msgSender.forceSafeTransferETH(refund);
            }
        } else {
            // ERC20 transfer
            paymentToken.safeTransferFrom2(msgSender, treasury, paymentAmount);
        }

        // transfer underlying tokens to recipient
        underlyingToken.safeTransfer(recipient, amount);

        emit Exercise(msgSender, recipient, amount, paymentAmount);
    }
}
