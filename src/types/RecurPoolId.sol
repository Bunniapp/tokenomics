// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {RecurPoolKey} from "./RecurPoolKey.sol";

type RecurPoolId is bytes32;

library RecurPoolIdLibrary {
    /// @notice Returns value equal to keccak256(abi.encode(key))
    function toId(RecurPoolKey memory key) internal pure returns (RecurPoolId poolId) {
        assembly ("memory-safe") {
            // 0x60 represents the total size of the RecurPoolKey struct (3 slots of 32 bytes)
            poolId := keccak256(key, 0x60)
        }
    }
}
