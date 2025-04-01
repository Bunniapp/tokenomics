// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "../base/CREATE3Script.sol";
import {OpBridger} from "../../src/bridgers/OpBridger.sol";

contract DeployScript is CREATE3Script {
    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (OpBridger bridger, bytes32 salt) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        address recipient = vm.envAddress("BRIDGER_RECIPIENT");
        address owner = vm.envAddress("OWNER");

        salt = getCreate3SaltFromEnv("Bridger");

        vm.startBroadcast(deployerPrivateKey);

        bridger = OpBridger(
            payable(create3.deploy(salt, bytes.concat(type(OpBridger).creationCode, abi.encode(recipient, owner))))
        );

        vm.stopBroadcast();
    }
}
