// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "./base/CREATE3Script.sol";
import {VeAirdrop} from "../src/VeAirdrop.sol";

contract DeployScript is CREATE3Script {
    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (VeAirdrop veAirdrop) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        bytes32 merkleRoot = vm.envBytes32("VEAIRDROP_MERKLE_ROOT");
        uint256 startTime = vm.envUint("VEAIRDROP_START_TIME");
        uint256 endTime = vm.envUint("VEAIRDROP_END_TIME");
        address votingEscrow = getCreate3Contract("veBUNNI");
        address owner = vm.envAddress("OWNER");

        vm.startBroadcast(deployerPrivateKey);

        veAirdrop = VeAirdrop(
            create3.deploy(
                getCreate3ContractSalt("VeAirdrop-veBUNNI"),
                bytes.concat(
                    type(VeAirdrop).creationCode, abi.encode(merkleRoot, startTime, endTime, votingEscrow, owner)
                )
            )
        );

        vm.stopBroadcast();
    }
}
