// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "./base/CREATE3Script.sol";
import {VyperDeployer} from "../src/lib/VyperDeployer.sol";
import {SmartWalletChecker} from "../src/SmartWalletChecker.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";

contract DeployScript is CREATE3Script, VyperDeployer {
    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (IVotingEscrow votingEscrow, SmartWalletChecker smartWalletChecker) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        address admin = vm.envAddress("OWNER");
        address token = getCreate3Contract("BUNNI");

        vm.startBroadcast(deployerPrivateKey);

        smartWalletChecker = SmartWalletChecker(
            create3.deploy(
                getCreate3ContractSalt("SmartWalletChecker-veBUNNI"),
                bytes.concat(type(SmartWalletChecker).creationCode, abi.encode(admin, new address[](0)))
            )
        );

        votingEscrow = IVotingEscrow(
            create3.deploy(
                getCreate3ContractSalt("veBUNNI"),
                bytes.concat(
                    compileContract("VotingEscrow"),
                    abi.encode(token, "Vote Escrowed BUNNI", "veBUNNI", admin, smartWalletChecker)
                )
            )
        );

        vm.stopBroadcast();
    }
}
