// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {LibMulticaller} from "multicaller/LibMulticaller.sol";

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IOracle} from "./interfaces/IOracle.sol";
import {ERC20Multicaller} from "./lib/ERC20Multicaller.sol";

/// @title Options Token
/// @author zefram.eth
/// @notice Options token representing the right to purchase the underlying token
/// at an oracle-specified rate. Similar to call options but with a variable strike
/// price that's always at a certain discount to the market price.
/// @dev Assumes the underlying token and the payment token both use 18 decimals.
contract OptionsToken is ERC20Multicaller, Ownable {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeTransferLib for *;
    using FixedPointMathLib for *;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error OptionsToken__PastDeadline();
    error OptionsToken__SlippageTooHigh();

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event Exercise(address indexed sender, address indexed recipient, uint256 amount, uint256 paymentAmount);
    event SetOracle(IOracle indexed newOracle);
    event SetTreasury(address indexed newTreasury);

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    /// @notice The token paid by the options token holder during redemption
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

    constructor(address owner_, IOracle oracle_, address treasury_) {
        paymentToken = oracle_.paymentToken();
        underlyingToken = oracle_.underlyingToken();
        oracle = oracle_;
        treasury = treasury_;

        emit SetOracle(oracle_);
        emit SetTreasury(treasury_);

        _initializeOwner(owner_);
    }

    /// -----------------------------------------------------------------------
    /// External functions
    /// -----------------------------------------------------------------------

    /// @notice Mints options tokens by taking underlying tokens from the sender.
    /// @param to The address that will receive the minted options tokens
    /// @param amount The amount of options tokens that will be minted
    function mint(address to, uint256 amount) external {
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
        underlyingToken.safeTransferFrom(msgSender, address(this), amount);
    }

    /// @notice Exercises options tokens to purchase the underlying tokens.
    /// The oracle may revert if it cannot give a secure result.
    /// @param amount The amount of options tokens to exercise
    /// @param maxPaymentAmount The maximum acceptable amount to pay. Used for slippage protection.
    /// @param recipient The recipient of the purchased underlying tokens
    /// @return paymentAmount The amount paid to the treasury to purchase the underlying tokens
    function exercise(uint256 amount, uint256 maxPaymentAmount, address recipient)
        external
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
        returns (uint256 paymentAmount)
    {
        if (block.timestamp > deadline) revert OptionsToken__PastDeadline();
        return _exercise(amount, maxPaymentAmount, recipient);
    }

    /// -----------------------------------------------------------------------
    /// Getters
    /// -----------------------------------------------------------------------

    function name() public pure override returns (string memory) {
        return "Bunni Options Token";
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

        // transfer payment tokens from msgSender to the treasury
        paymentAmount = amount.mulWadUp(oracle.getPrice());
        if (paymentAmount > maxPaymentAmount) revert OptionsToken__SlippageTooHigh();
        paymentToken.safeTransferFrom(msgSender, treasury, paymentAmount);

        // transfer underlying tokens to recipient
        underlyingToken.safeTransfer(recipient, amount);

        emit Exercise(msgSender, recipient, amount, paymentAmount);
    }
}
