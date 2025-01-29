// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "./base/CREATE3Script.sol";
import {VyperDeployer} from "../src/lib/VyperDeployer.sol";
import {SmartWalletChecker} from "../src/SmartWalletChecker.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";

contract DeployScript is CREATE3Script, VyperDeployer {
    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run()
        external
        returns (
            IVotingEscrow votingEscrow,
            SmartWalletChecker smartWalletChecker,
            bytes32 veSalt,
            bytes32 smartWalletSalt
        )
    {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        address admin = vm.envAddress("OWNER");
        address token = getCreate3ContractFromEnvSalt("BUNNI");

        veSalt = getCreate3SaltFromEnv("veBUNNI");
        smartWalletSalt = getCreate3SaltFromEnv("SmartWalletChecker");

        vm.startBroadcast(deployerPrivateKey);

        smartWalletChecker = SmartWalletChecker(
            create3.deploy(
                smartWalletSalt,
                bytes.concat(type(SmartWalletChecker).creationCode, abi.encode(admin, new address[](0)))
            )
        );

        votingEscrow = IVotingEscrow(
            create3.deploy(
                veSalt,
                bytes.concat(
                    compileContract("VotingEscrow"),
                    abi.encode(token, "Vote Escrowed BUNNI", "veBUNNI", admin, smartWalletChecker)
                )
            )
        );

        vm.stopBroadcast();
    }
}
