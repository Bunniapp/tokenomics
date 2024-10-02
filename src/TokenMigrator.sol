// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.11;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title TokenMigrator
/// @author zefram.eth
/// @notice Used for migrating from an existing ERC20 token to a new ERC20 token
contract TokenMigrator is Ownable {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using FixedPointMathLib for *;
    using SafeTransferLib for address;

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event Migrate(address indexed sender, address indexed recipient, uint256 oldTokenAmount, uint256 newTokenAmount);
    event WithdrawNewToken(address indexed sender, address indexed recipient, uint256 amount);
    event SetNewTokenPerOldToken(uint256 newTokenPerOldToken);

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    /// @notice The old token that's being phased out
    address public immutable oldToken;

    /// @notice The new token that's being migrated to
    address public immutable newToken;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    /// @notice The amount of new tokens to give for each old token migrated, 18 decimals.
    /// @dev Assumes both tokens use the same number of decimals.
    uint256 public newTokenPerOldToken;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(address oldToken_, address newToken_, uint256 newTokenPerOldToken_, address owner_) {
        oldToken = oldToken_;
        newToken = newToken_;

        newTokenPerOldToken = newTokenPerOldToken_;
        emit SetNewTokenPerOldToken(newTokenPerOldToken_);

        _initializeOwner(owner_);
    }

    /// -----------------------------------------------------------------------
    /// User actions
    /// -----------------------------------------------------------------------

    /// @notice Migrates old tokens to new tokens
    /// @param oldTokenAmount The amount of old tokens to migrate
    /// @param recipient The address that will receive the new tokens
    /// @return newTokenAmount The amount of new tokens received
    function migrate(uint256 oldTokenAmount, address recipient) external returns (uint256 newTokenAmount) {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        // if migrating 0, just do nothing
        if (oldTokenAmount == 0) {
            return 0;
        }

        /// -----------------------------------------------------------------------
        /// Effects
        /// -----------------------------------------------------------------------

        // calculate new token amount
        newTokenAmount = oldTokenAmount.mulWad(newTokenPerOldToken);

        // transfer old tokens from sender and lock
        oldToken.safeTransferFrom(msg.sender, address(this), oldTokenAmount);

        // transfer new tokens to recipient
        newToken.safeTransfer(recipient, newTokenAmount);

        emit Migrate(msg.sender, recipient, oldTokenAmount, newTokenAmount);
    }

    /// -----------------------------------------------------------------------
    /// Owner actions
    /// -----------------------------------------------------------------------

    /// @notice Withdraws new tokens from this contract. Only callable by owner.
    /// @param amount The amount of new tokens to withdraw
    /// @param recipient The address that will receive the new tokens
    function withdrawNewToken(uint256 amount, address recipient) external onlyOwner {
        newToken.safeTransfer(recipient, amount);
        emit WithdrawNewToken(msg.sender, recipient, amount);
    }

    /// @notice Sets the amount of new tokens to give for each old token migrated. Only callable by owner.
    /// @param newTokenPerOldToken_ The amount of new tokens to give for each old token migrated, 18 decimals.
    function setNewTokenPerOldToken(uint256 newTokenPerOldToken_) external onlyOwner {
        newTokenPerOldToken = newTokenPerOldToken_;
        emit SetNewTokenPerOldToken(newTokenPerOldToken_);
    }
}
