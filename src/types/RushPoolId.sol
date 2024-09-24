// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {RushPoolKey} from "./RushPoolKey.sol";

type RushPoolId is bytes32;

library RushPoolIdLibrary {
    /// @notice Returns value equal to keccak256(abi.encode(key))
    function toId(RushPoolKey memory key) internal pure returns (RushPoolId poolId) {
        assembly ("memory-safe") {
            // 0x80 represents the total size of the RushPoolKey struct (4 slots of 32 bytes)
            poolId := keccak256(key, 0x80)
        }
    }
}
