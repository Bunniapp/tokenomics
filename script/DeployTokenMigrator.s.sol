// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "./base/CREATE3Script.sol";
import {TokenMigrator} from "../src/TokenMigrator.sol";

contract DeployScript is CREATE3Script {
    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (TokenMigrator migrator) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        address oldToken = vm.envAddress("OLD_TOKEN");
        address newToken = vm.envAddress("NEW_TOKEN");
        uint256 newTokenPerOldToken = vm.envUint("NEW_TOKEN_PER_OLD_TOKEN");
        address owner = vm.envAddress("OWNER");

        vm.startBroadcast(deployerPrivateKey);

        migrator = TokenMigrator(
            create3.deploy(
                getCreate3ContractSalt("TokenMigrator"),
                bytes.concat(
                    type(TokenMigrator).creationCode, abi.encode(oldToken, newToken, newTokenPerOldToken, owner)
                )
            )
        );

        vm.stopBroadcast();
    }
}
