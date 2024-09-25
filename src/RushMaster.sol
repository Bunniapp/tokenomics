// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {RushPoolId} from "./types/RushPoolId.sol";
import {RushPoolKey} from "./types/RushPoolKey.sol";
import {ReentrancyGuard} from "./lib/ReentrancyGuard.sol";
import {IERC20Unlocker} from "./external/IERC20Unlocker.sol";
import {IERC20Lockable} from "./external/IERC20Lockable.sol";

struct IncentiveParams {
    RushPoolKey key;
    uint256 incentiveAmount;
}

struct StakeState {
    uint256 stakeAmount;
    uint256 stakeXTimeStored;
    uint256 lastStakeAmountUpdateTimestamp;
}

struct LockCallbackData {
    RushPoolKey[] keys;
}

struct ClaimParams {
    RushPoolKey key;
    ERC20[] incentiveTokens;
}

contract RushMaster is IERC20Unlocker, ReentrancyGuard {
    using FixedPointMathLib for *;
    using SafeTransferLib for address;

    uint256 internal constant PRECISION = 1e30;

    mapping(RushPoolId id => StakeState) public poolStates;
    mapping(RushPoolId id => mapping(ERC20 incentiveToken => uint256)) public incentiveAmounts;
    mapping(RushPoolId id => mapping(ERC20 incentiveToken => mapping(address depositor => uint256))) public
        incentiveDeposits;

    mapping(RushPoolId id => mapping(address user => StakeState)) public userStates;
    mapping(address user => mapping(IERC20Lockable stakeToken => uint256)) public userPoolCounts;
    mapping(RushPoolId id => mapping(address user => mapping(ERC20 incentiveToken => uint256))) public userRewardPaid;

    /// -----------------------------------------------------------------------
    /// Incentivizer actions
    /// -----------------------------------------------------------------------

    /// @notice Deposits an incentive token to a list of RushPools. Should be called before the RushPools are active.
    /// If one of the RushPools is already active, the incentive will not be pulled from the caller or deposited into the RushPool.
    /// @param params The list of RushPools to deposit the incentive into and the amount to deposit.
    /// @param incentiveToken The incentive token to deposit.
    /// @param recipient The address that will receive the right to withdraw the incentive tokens.
    /// @return totalIncentiveAmount The total amount of incentive tokens deposited.
    function depositIncentive(IncentiveParams[] calldata params, ERC20 incentiveToken, address recipient)
        external
        nonReentrant
        returns (uint256 totalIncentiveAmount)
    {
        // record incentive in each pool
        for (uint256 i; i < params.length; i++) {
            if (block.timestamp >= params[i].key.startTimestamp) {
                // program is already active, skip
                continue;
            }

            // sum up incentive amount
            totalIncentiveAmount += params[i].incentiveAmount;

            RushPoolId id = params[i].key.toId();

            // add incentive to pool
            incentiveAmounts[id][incentiveToken] += params[i].incentiveAmount;

            // add incentive to depositor
            incentiveDeposits[id][incentiveToken][recipient] += params[i].incentiveAmount;
        }

        // transfer incentive tokens to this contract
        if (totalIncentiveAmount != 0) {
            address(incentiveToken).safeTransferFrom(msg.sender, address(this), totalIncentiveAmount);
        }
    }

    /// @notice Withdraws an incentive token from a list of RushPools. Should be called before the RushPools are active.
    /// If one of the RushPools is already active, the corresponding incentive will not be withdrawn from.
    /// @param params The list of RushPools to withdraw the incentive from and the amount to withdraw.
    /// @param incentiveToken The incentive token to withdraw.
    /// @param recipient The address that will receive the withdrawn incentive tokens.
    /// @return totalWithdrawnAmount The total amount of incentive tokens withdrawn.
    function withdrawIncentive(IncentiveParams[] calldata params, ERC20 incentiveToken, address recipient)
        external
        nonReentrant
        returns (uint256 totalWithdrawnAmount)
    {
        // subtract incentive tokens from each pool
        for (uint256 i; i < params.length; i++) {
            if (block.timestamp >= params[i].key.startTimestamp) {
                // program is already active, skip
                continue;
            }

            // sum up withdrawn amount
            totalWithdrawnAmount += params[i].incentiveAmount;

            RushPoolId id = params[i].key.toId();

            // subtract incentive from pool
            incentiveAmounts[id][incentiveToken] -= params[i].incentiveAmount;

            // subtract incentive from sender
            incentiveDeposits[id][incentiveToken][msg.sender] -= params[i].incentiveAmount;
        }

        // transfer incentive tokens to recipient
        if (totalWithdrawnAmount != 0) {
            address(incentiveToken).safeTransfer(recipient, totalWithdrawnAmount);
        }
    }

    /// @notice Refund unused incentive tokens deposited by msg.sender. Should be called after the RushPools are over.
    /// @param params The list of RushPools to refund the incentive into and the incentive tokens to refund.
    /// @param recipient The address that will receive the refunded incentive tokens.
    function refundIncentive(ClaimParams[] calldata params, address recipient) external nonReentrant {
        for (uint256 i; i < params.length; i++) {
            // the program should be over
            if (block.timestamp > params[i].key.startTimestamp + params[i].key.programLength) {
                continue;
            }

            RushPoolId id = params[i].key.toId();
            StakeState memory poolState = poolStates[id];
            uint256 stakeXTimeUpdated = _computeStakeXTime(
                params[i].key,
                poolState.stakeXTimeStored,
                poolState.stakeAmount,
                poolState.lastStakeAmountUpdateTimestamp
            );
            for (uint256 j; j < params[i].incentiveTokens.length; j++) {
                ERC20 incentiveToken = params[i].incentiveTokens[j];
                uint256 incentiveAmount = incentiveDeposits[id][incentiveToken][msg.sender]; // the incentives added by msg.sender
                if (incentiveAmount == 0) {
                    continue;
                }

                // refund amount is the provided incentive amount minus the reward paid to stakers
                uint256 rewardAccured = incentiveAmount.mulDiv(stakeXTimeUpdated, PRECISION);
                uint256 refundAmount = incentiveAmount - rewardAccured;

                // delete incentive deposit to mark the incentive as refunded
                delete incentiveDeposits[id][incentiveToken][msg.sender];

                // transfer refund amount to recipient
                if (refundAmount != 0) {
                    address(incentiveToken).safeTransfer(recipient, refundAmount);
                }
            }
        }
    }

    /// -----------------------------------------------------------------------
    /// Staker actions
    /// -----------------------------------------------------------------------

    /// @notice Joins a list of RushPools. Can join a pool where the user has existing stake if more capacity has opened up.
    /// @param keys The list of RushPools to join.
    function join(RushPoolKey[] calldata keys) external {
        for (uint256 i; i < keys.length; i++) {
            // pool needs to be active
            if (
                block.timestamp < keys[i].startTimestamp
                    || block.timestamp > keys[i].startTimestamp + keys[i].programLength
            ) {
                continue;
            }

            RushPoolId id = keys[i].toId();
            StakeState memory userState = userStates[id][msg.sender];
            StakeState memory poolState = poolStates[id];
            uint256 remainderStakeAmount = poolState.stakeAmount - userState.stakeAmount; // stake in pool minus the user's existing stake
            uint256 stakeAmountUpdated;
            {
                uint256 balance = keys[i].stakeToken.balanceOf(msg.sender);
                stakeAmountUpdated = remainderStakeAmount + balance > keys[i].stakeCap
                    ? keys[i].stakeCap - remainderStakeAmount
                    : balance;
            }

            // ensure there is capacity left and that we're increasing the user's stake
            // the user's stake may increase when either
            // 1) the user isn't staked yet or
            // 2) the user staked & hit the stake cap but more capacity has opened up since then
            if (stakeAmountUpdated == 0 || stakeAmountUpdated <= userState.stakeAmount) {
                continue;
            }

            // update user state
            // block.timestamp is at most endTimestamp
            // since we already checked that the program is active
            uint256 userStakeXTimeUpdated = _computeStakeXTime(
                keys[i], userState.stakeXTimeStored, userState.stakeAmount, userState.lastStakeAmountUpdateTimestamp
            );
            userStates[id][msg.sender] = StakeState({
                stakeAmount: stakeAmountUpdated,
                stakeXTimeStored: userStakeXTimeUpdated,
                lastStakeAmountUpdateTimestamp: block.timestamp
            });
            if (userState.stakeAmount == 0) {
                // user didn't have any stake in this pool before
                ++userPoolCounts[msg.sender][keys[i].stakeToken];
            }

            // update pool state
            // poolState.lastStakeAmountUpdateTimestamp might be 0 if the pool has never had stakers
            // so we bound it by the start timestamp of the program
            uint256 poolStakeXTimeUpdated = _computeStakeXTime(
                keys[i],
                poolState.stakeXTimeStored,
                poolState.stakeAmount,
                FixedPointMathLib.max(poolState.lastStakeAmountUpdateTimestamp, keys[i].startTimestamp)
            );
            poolStates[id] = StakeState({
                stakeAmount: remainderStakeAmount + stakeAmountUpdated,
                stakeXTimeStored: poolStakeXTimeUpdated,
                lastStakeAmountUpdateTimestamp: block.timestamp
            });
        }
    }

    /// @notice Exits a list of RushPools.
    /// @param keys The list of RushPools to exit.
    function exit(RushPoolKey[] calldata keys) external {
        for (uint256 i; i < keys.length; i++) {
            // should be past pool's start timestamp
            if (block.timestamp < keys[i].startTimestamp) {
                continue;
            }

            RushPoolId id = keys[i].toId();
            StakeState memory userState = userStates[id][msg.sender];

            // user should have staked in the pool
            if (userState.stakeAmount == 0) {
                continue;
            }

            // update user state
            uint256 endTimestamp = keys[i].startTimestamp + keys[i].programLength;
            uint256 latestActiveTimestamp = FixedPointMathLib.min(block.timestamp, endTimestamp);
            uint256 userStakeXTimeUpdated = _computeStakeXTime(
                keys[i], userState.stakeXTimeStored, userState.stakeAmount, userState.lastStakeAmountUpdateTimestamp
            );
            userStates[id][msg.sender] = StakeState({
                stakeAmount: 0,
                stakeXTimeStored: userStakeXTimeUpdated,
                lastStakeAmountUpdateTimestamp: latestActiveTimestamp
            });
            --userPoolCounts[msg.sender][keys[i].stakeToken];

            // update pool state
            StakeState memory poolState = poolStates[id];
            uint256 poolStakeXTimeUpdated = _computeStakeXTime(
                keys[i], poolState.stakeXTimeStored, poolState.stakeAmount, poolState.lastStakeAmountUpdateTimestamp
            );
            poolStates[id] = StakeState({
                stakeAmount: poolState.stakeAmount - userState.stakeAmount,
                stakeXTimeStored: poolStakeXTimeUpdated,
                lastStakeAmountUpdateTimestamp: latestActiveTimestamp
            });
        }
    }

    function unlock(IERC20Lockable[] calldata stakeTokens) external {}

    /// @notice Claims accrued incentives for a list of RushPools that msg.sender has staked in.
    /// @param params The list of RushPools to claim the incentives for and the incentive tokens to claim.
    /// @param recipient The address that will receive the claimed incentive tokens.
    function claim(ClaimParams[] calldata params, address recipient) external nonReentrant {
        for (uint256 i; i < params.length; i++) {
            RushPoolId id = params[i].key.toId();
            StakeState memory userState = userStates[id][msg.sender];
            uint256 stakeXTimeUpdated = _computeStakeXTime(
                params[i].key,
                userState.stakeXTimeStored,
                userState.stakeAmount,
                userState.lastStakeAmountUpdateTimestamp
            );

            for (uint256 j; j < params[i].incentiveTokens.length; j++) {
                // compute reward
                ERC20 incentiveToken = params[i].incentiveTokens[j];
                uint256 incentiveAmount = incentiveAmounts[id][incentiveToken];
                uint256 rewardPaid = userRewardPaid[id][msg.sender][incentiveToken];
                uint256 rewardAccured = incentiveAmount.mulDiv(stakeXTimeUpdated, PRECISION);
                uint256 claimableReward = rewardAccured - rewardPaid;

                // update claim state
                userRewardPaid[id][msg.sender][incentiveToken] = rewardAccured;

                // transfer incentive tokens to user
                address(incentiveToken).safeTransfer(recipient, claimableReward);
            }
        }
    }

    /// -----------------------------------------------------------------------
    /// Callbacks
    /// -----------------------------------------------------------------------

    /// @inheritdoc IERC20Unlocker
    /// @dev Should initialize the user's stake position.
    function lockCallback(address account, uint256 balance, bytes calldata data) external {
        LockCallbackData memory callbackData = abi.decode(data, (LockCallbackData));
        IERC20Lockable stakeToken = IERC20Lockable(msg.sender);

        for (uint256 i; i < callbackData.keys.length; i++) {
            // stakeToken of key should be msg.sender
            if (callbackData.keys[i].stakeToken != stakeToken) {
                continue;
            }

            // pool needs to be active
            uint256 endTimestamp = callbackData.keys[i].startTimestamp + callbackData.keys[i].programLength;
            if (block.timestamp < callbackData.keys[i].startTimestamp || block.timestamp > endTimestamp) {
                continue;
            }

            RushPoolId id = callbackData.keys[i].toId();
            uint256 userStakeAmount = userStates[id][account].stakeAmount;
            // can't stake in a pool twice
            if (userStakeAmount != 0) {
                continue;
            }
            StakeState memory poolState = poolStates[id];
            uint256 stakeAmount = poolState.stakeAmount + balance > callbackData.keys[i].stakeCap
                ? callbackData.keys[i].stakeCap - poolState.stakeAmount
                : balance;
            // ensure there is capacity left
            if (stakeAmount == 0) {
                continue;
            }

            // update user state
            // leave stakeXTime unchanged since stakeAmount was zero since the last update
            // block.timestamp is at most endTimestamp
            // since we already checked that the program is active
            userStates[id][account].stakeAmount = stakeAmount;
            userStates[id][account].lastStakeAmountUpdateTimestamp = block.timestamp;
            ++userPoolCounts[account][callbackData.keys[i].stakeToken];

            // update pool state
            // poolState.lastStakeAmountUpdateTimestamp might be 0 if the pool has never had stakers
            // so we bound it by the start timestamp of the program
            uint256 stakeXTimeUpdated = _computeStakeXTime(
                callbackData.keys[i],
                poolState.stakeXTimeStored,
                poolState.stakeAmount,
                FixedPointMathLib.max(poolState.lastStakeAmountUpdateTimestamp, callbackData.keys[i].startTimestamp)
            );
            poolStates[id] = StakeState({
                stakeAmount: poolState.stakeAmount + stakeAmount,
                stakeXTimeStored: stakeXTimeUpdated,
                lastStakeAmountUpdateTimestamp: block.timestamp
            });
        }
    }

    /// @inheritdoc IERC20Unlocker
    function lockedUserReceiveCallback(address account, uint256 receiveAmount) external {}

    /// -----------------------------------------------------------------------
    /// Internal utilities
    /// -----------------------------------------------------------------------

    /// @dev Computes the updated (normalized stake amount) x (normalized time since program start) value. This value is useful
    /// since (stake x time) x (incentive amount) is the incentive amount accrued for the user / pool so far.
    /// Example: If a user has staked 0.5 x stakeCap tokens for 0.3 x programLength seconds, the stake x time value is 0.15 which is
    /// the proportion of the total incentive amount that the user has accrued so far.
    /// @param key The rush pool key.
    /// @param stakeXTimeStored The stake x time value stored in the state.
    /// @param stakeAmount The stake amount of the user between the last update and now.
    /// @param lastStakeAmountUpdateTimestamp The timestamp of the last update. Should be at most the end timestamp of the program.
    /// @return The updated stake x time value.
    function _computeStakeXTime(
        RushPoolKey memory key,
        uint256 stakeXTimeStored,
        uint256 stakeAmount,
        uint256 lastStakeAmountUpdateTimestamp
    ) internal view returns (uint256) {
        if (block.timestamp < key.startTimestamp) {
            return 0;
        }
        uint256 endTimestamp = key.startTimestamp + key.programLength;
        uint256 timeElapsedSinceLastUpdate =
            FixedPointMathLib.min(block.timestamp, endTimestamp) - lastStakeAmountUpdateTimestamp;
        return stakeXTimeStored
            + stakeAmount.mulDiv(PRECISION, key.stakeCap).mulDiv(timeElapsedSinceLastUpdate, key.programLength);
    }
}
