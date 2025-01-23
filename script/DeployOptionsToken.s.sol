// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {CREATE3Script} from "./base/CREATE3Script.sol";
import {OptionsToken} from "../src/OptionsToken.sol";
import {BunniHookOracle} from "../src/oracles/BunniHookOracle.sol";
import {PoolKey} from "../src/external/IBunniHook.sol";

contract DeployScript is CREATE3Script {
    using SafeCastLib for *;

    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (OptionsToken optionsToken, BunniHookOracle oracle) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        address bunniHook = vm.envAddress("BUNNI_HOOK");
        address paymentToken = vm.envAddress("PAYMENT_TOKEN");
        address underlyingToken = getCreate3Contract("BUNNI");
        uint24 fee = vm.envUint("ORACLE_POOLKEY_FEE").toUint24();
        int24 tickSpacing = vm.envUint("ORACLE_POOLKEY_TICK_SPACING").toInt256().toInt24();
        uint16 oracleMultiplier = vm.envUint("ORACLE_MULTIPLIER").toUint16();
        uint32 oracleSecs = vm.envUint("ORACLE_SECS").toUint32();
        uint32 oracleAgo = vm.envUint("ORACLE_AGO").toUint32();
        uint128 oracleMinPrice = vm.envUint("ORACLE_MIN_PRICE").toUint128();
        uint256[] memory minterLimits = vm.envUint("BUNNI_MINTER_LIMITS", ",");
        uint256[] memory burnerLimits = vm.envUint("BUNNI_BURNER_LIMITS", ",");
        address[] memory bridges = vm.envAddress("BUNNI_BRIDGES", ",");

        (address currency0, address currency1) = address(paymentToken) < address(underlyingToken)
            ? (address(paymentToken), address(underlyingToken))
            : (address(underlyingToken), address(paymentToken));
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: bunniHook});

        address owner = vm.envAddress("OWNER");
        address treasury = vm.envAddress("TREASURY");

        vm.startBroadcast(deployerPrivateKey);

        oracle = BunniHookOracle(
            create3.deploy(
                getCreate3ContractSalt("BunniHookOracle"),
                bytes.concat(
                    type(BunniHookOracle).creationCode,
                    abi.encode(
                        bunniHook,
                        key,
                        paymentToken,
                        underlyingToken,
                        owner,
                        oracleMultiplier,
                        oracleSecs,
                        oracleAgo,
                        oracleMinPrice
                    )
                )
            )
        );
        optionsToken = OptionsToken(
            create3.deploy(
                getCreate3ContractSalt("oBUNNI"),
                bytes.concat(
                    type(OptionsToken).creationCode,
                    abi.encode(owner, oracle, treasury, minterLimits, burnerLimits, bridges)
                )
            )
        );

        vm.stopBroadcast();
    }
}
