// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "./base/CREATE3Script.sol";
import {L2BUNNI} from "../src/L2BUNNI.sol";

contract DeployScript is CREATE3Script {
    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (L2BUNNI bunni, bytes32 salt) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        address owner = vm.envAddress("OWNER");
        uint256[] memory minterLimits = vm.envUint("BUNNI_MINTER_LIMITS", ",");
        uint256[] memory burnerLimits = vm.envUint("BUNNI_BURNER_LIMITS", ",");
        address[] memory bridges = vm.envAddress("BUNNI_BRIDGES", ",");

        salt = getCreate3SaltFromEnv("BUNNI");

        vm.startBroadcast(deployerPrivateKey);

        bunni = L2BUNNI(
            create3.deploy(
                salt, bytes.concat(type(L2BUNNI).creationCode, abi.encode(owner, minterLimits, burnerLimits, bridges))
            )
        );

        vm.stopBroadcast();
    }
}
