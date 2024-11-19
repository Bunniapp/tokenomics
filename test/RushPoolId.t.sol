// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import "forge-std/Test.sol";

import "../src/types/RushPoolId.sol";
import {RushPoolKey} from "../src/types/RushPoolKey.sol";

contract RushPoolIdTest is Test {
    using RushPoolIdLibrary for RushPoolKey;

    function test_toId(RushPoolKey memory key) public pure {
        RushPoolId id = key.toId();
        assertEq(RushPoolId.unwrap(id), keccak256(abi.encode(key)));
    }
}
