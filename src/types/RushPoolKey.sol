// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {RushPoolIdLibrary} from "./RushPoolId.sol";
import {IERC20Lockable} from "../external/IERC20Lockable.sol";

using RushPoolIdLibrary for RushPoolKey global;

struct RushPoolKey {
    IERC20Lockable stakeToken;
    uint256 stakeCap;
    uint256 startTimestamp;
    uint256 programLength;
}
