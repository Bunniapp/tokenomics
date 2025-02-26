// SPDX-License-Identifier: MIT

pragma solidity >=0.5.0;

import "../../src/external/IBunniHook.sol";

interface IBunniHub {
    /// @param currency0 The token0 of the Uniswap V4 pool
    /// @param currency1 The token1 of the Uniswap V4 pool
    /// @param tickSpacing The tick spacing of the Uniswap V4 pool
    /// @param twapSecondsAgo The TWAP time period to use for the liquidity density function
    /// @param liquidityDensityFunction The liquidity density function to use
    /// @param ldfType The type of LDF. See LDFType.sol for details.
    /// @param hooklet The hooklet to use for the Bunni pool. If it's address(0), then a hooklet is not used.
    /// @param ldfParams The parameters for the liquidity density function
    /// @param hooks The hooks to use for the Uniswap V4 pool
    /// @param hookParams The parameters for the hooks
    /// @param vault0 The vault for token0. If address(0), then a vault is not used.
    /// @param vault1 The vault for token1. If address(0), then a vault is not used.
    /// @param minRawTokenRatio0 The minimum (rawBalance / balance) ratio for token0
    /// @param targetRawTokenRatio0 The target (rawBalance / balance) ratio for token0
    /// @param maxRawTokenRatio0 The maximum (rawBalance / balance) ratio for token0
    /// @param minRawTokenRatio1 The minimum (rawBalance / balance) ratio for token1
    /// @param targetRawTokenRatio1 The target (rawBalance / balance) ratio for token1
    /// @param maxRawTokenRatio1 The maximum (rawBalance / balance) ratio for token1
    /// @param sqrtPriceX96 The initial sqrt price of the Uniswap V4 pool
    /// @param name The name of the BunniToken
    /// @param symbol The symbol of the BunniToken
    /// @param owner The owner of the BunniToken. Only has the power to set the metadata URI.
    /// @param metadataURI The initial metadata URI of the BunniToken, containing info like description, image, etc.
    /// @param salt The salt for deploying the BunniToken via CREATE3.
    struct DeployBunniTokenParams {
        address currency0;
        address currency1;
        int24 tickSpacing;
        uint24 twapSecondsAgo;
        address liquidityDensityFunction;
        address hooklet;
        uint8 ldfType;
        bytes32 ldfParams;
        IBunniHook hooks;
        bytes hookParams;
        address vault0;
        address vault1;
        uint24 minRawTokenRatio0;
        uint24 targetRawTokenRatio0;
        uint24 maxRawTokenRatio0;
        uint24 minRawTokenRatio1;
        uint24 targetRawTokenRatio1;
        uint24 maxRawTokenRatio1;
        uint160 sqrtPriceX96;
        bytes32 name;
        bytes32 symbol;
        address owner;
        string metadataURI;
        bytes32 salt;
    }

    /// @notice Deploys the BunniToken contract for a Bunni position. This token
    /// represents a user's share in the Uniswap V4 LP position.
    /// @dev The BunniToken is deployed via CREATE3, which allows for a deterministic address.
    /// @param params The input parameters
    /// currency0 The token0 of the Uniswap V4 pool
    /// currency1 The token1 of the Uniswap V4 pool
    /// tickSpacing The tick spacing of the Uniswap V4 pool
    /// twapSecondsAgo The TWAP time period to use for the liquidity density function
    /// liquidityDensityFunction The liquidity density function to use
    /// hooklet The hooklet to use for the Bunni pool. If it's address(0), then a hooklet is not used.
    /// ldfParams The parameters for the liquidity density function
    /// hooks The hooks to use for the Uniswap V4 pool
    /// hookParams The parameters for the hooks
    /// vault0 The vault for token0. If address(0), then a vault is not used.
    /// vault1 The vault for token1. If address(0), then a vault is not used.
    /// minRawTokenRatio0 The minimum (rawBalance / balance) ratio for token0
    /// targetRawTokenRatio0 The target (rawBalance / balance) ratio for token0
    /// maxRawTokenRatio0 The maximum (rawBalance / balance) ratio for token0
    /// minRawTokenRatio1 The minimum (rawBalance / balance) ratio for token1
    /// targetRawTokenRatio1 The target (rawBalance / balance) ratio for token1
    /// maxRawTokenRatio1 The maximum (rawBalance / balance) ratio for token1
    /// sqrtPriceX96 The initial sqrt price of the Uniswap V4 pool
    /// name The name of the BunniToken
    /// symbol The symbol of the BunniToken
    /// owner The owner of the BunniToken. Only has the power to set the metadata URI.
    /// metadataURI The initial metadata URI of the BunniToken, containing info like description, image, etc.
    /// salt The salt for deploying the BunniToken via CREATE3.
    /// @return token The deployed BunniToken
    /// @return key The PoolKey of the Uniswap V4 pool
    function deployBunniToken(DeployBunniTokenParams calldata params)
        external
        returns (address token, PoolKey memory key);
}
