// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "./base/CREATE3Script.sol";
import {IMasterBunni} from "../src/interfaces/IMasterBunni.sol";
import {MasterBunni} from "../src/MasterBunni.sol";

contract DeployScript is CREATE3Script {
    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (IMasterBunni masterBunni, bytes32 salt) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        salt = getCreate3SaltFromEnv("MasterBunni");

        vm.startBroadcast(deployerPrivateKey);

        masterBunni = IMasterBunni(create3.deploy(salt, type(MasterBunni).creationCode));

        vm.stopBroadcast();
    }
}
