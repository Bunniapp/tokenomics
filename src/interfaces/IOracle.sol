// SPDX-License-Identifier: AGPL-3.0

pragma solidity >=0.7.0 <0.9.0;

/// @title Interface for an oracle of the options token's strike price
/// @author zefram.eth
/// @notice An oracle of the options token's strike price
interface IOracle {
    /// @notice Computes the current strike price of the option
    /// @return price The strike price in terms of the payment token, scaled by 18 decimals.
    /// For example, if the payment token is $2 and the strike price is $4, the return value
    /// would be 2e18. Unit is (paymentToken / underlyingToken), e.g. (WETH/BUNNI)
    function getPrice() external view returns (uint256 price);

    /// @notice Returns the payment token, which is the token the user pays to exercise the option.
    function paymentToken() external view returns (address);

    /// @notice Returns the underlying token, which is the token the user receives when exercising the option.
    function underlyingToken() external view returns (address);
}
