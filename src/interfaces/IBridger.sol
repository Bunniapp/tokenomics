// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

/// @notice Interface for a contract that bridges ETH from an L2 to Ethereum.
/// @dev Supports unwrapping WETH to ETH before bridging. Needs keeper to regularly
/// call `bridge()`.
interface IBridger {
    /// @notice Bridges the WETH + ETH balance to Ethereum
    function bridge() external returns (uint256 amountBridged);

    /// @notice Returns the address that receives the bridged ETH
    function recipient() external view returns (address);

    /// @notice Returns the WETH token address
    function weth() external view returns (address);
}
