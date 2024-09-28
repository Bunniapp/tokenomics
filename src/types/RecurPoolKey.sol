// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {RecurPoolIdLibrary} from "./RecurPoolId.sol";
import {IERC20Lockable} from "../external/IERC20Lockable.sol";

using RecurPoolIdLibrary for RecurPoolKey global;

struct RecurPoolKey {
    IERC20Lockable stakeToken;
    address rewardToken;
    uint256 duration;
}
