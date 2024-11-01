// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {LibMulticaller} from "multicaller/LibMulticaller.sol";

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {RushPoolId} from "./types/RushPoolId.sol";
import {RushPoolKey} from "./types/RushPoolKey.sol";
import {RecurPoolId} from "./types/RecurPoolId.sol";
import {RecurPoolKey} from "./types/RecurPoolKey.sol";
import {ReentrancyGuard} from "./lib/ReentrancyGuard.sol";
import {IMasterBunni} from "./interfaces/IMasterBunni.sol";
import {IERC20Unlocker} from "./external/IERC20Unlocker.sol";
import {IERC20Lockable} from "./external/IERC20Lockable.sol";

contract MasterBunni is IMasterBunni, ReentrancyGuard {
    using FixedPointMathLib for *;
    using SafeTransferLib for address;

    uint256 internal constant PRECISION = 1e36;
    uint256 internal constant REWARD_RATE_PRECISION = 1e6;
    uint256 internal constant PRECISION_DIV_REWARD_RATE_PRECISION = PRECISION / REWARD_RATE_PRECISION;

    mapping(address user => mapping(IERC20Lockable stakeToken => uint256)) public userPoolCounts;

    mapping(RushPoolId id => RushStakeState) public rushPoolStates;
    mapping(RushPoolId id => mapping(address incentiveToken => uint256)) public rushPoolIncentiveAmounts;
    mapping(RushPoolId id => mapping(address incentiveToken => mapping(address depositor => uint256))) public
        rushPoolIncentiveDeposits;
    mapping(RushPoolId id => mapping(address user => RushStakeState)) public rushPoolUserStates;
    mapping(RushPoolId id => mapping(address user => mapping(address incentiveToken => uint256))) public
        rushPoolUserRewardPaid;

    mapping(RecurPoolId id => RecurPoolState) public recurPoolStates;

    /// -----------------------------------------------------------------------
    /// Incentivizer actions
    /// -----------------------------------------------------------------------

    /// @inheritdoc IMasterBunni
    function depositIncentive(RushIncentiveParams[] calldata params, address incentiveToken, address recipient)
        external
        nonReentrant
        returns (uint256 totalIncentiveAmount)
    {
        address msgSender = LibMulticaller.senderOrSigner();

        // record incentive in each pool
        for (uint256 i; i < params.length; i++) {
            if (!isValidRushPoolKey(params[i].key) || block.timestamp >= params[i].key.startTimestamp) {
                // key is invalid or program is already active, skip
                continue;
            }

            // sum up incentive amount
            totalIncentiveAmount += params[i].incentiveAmount;

            RushPoolId id = params[i].key.toId();

            // add incentive to pool
            rushPoolIncentiveAmounts[id][incentiveToken] += params[i].incentiveAmount;

            // add incentive to depositor
            rushPoolIncentiveDeposits[id][incentiveToken][recipient] += params[i].incentiveAmount;
        }

        // transfer incentive tokens to this contract
        if (totalIncentiveAmount != 0) {
            incentiveToken.safeTransferFrom2(msgSender, address(this), totalIncentiveAmount);
        }

        // emit event
        emit DepositIncentive(msgSender, incentiveToken, recipient, params, totalIncentiveAmount);
    }

    /// @inheritdoc IMasterBunni
    function withdrawIncentive(RushIncentiveParams[] calldata params, address incentiveToken, address recipient)
        external
        nonReentrant
        returns (uint256 totalWithdrawnAmount)
    {
        address msgSender = LibMulticaller.senderOrSigner();

        // subtract incentive tokens from each pool
        for (uint256 i; i < params.length; i++) {
            if (!isValidRushPoolKey(params[i].key) || block.timestamp >= params[i].key.startTimestamp) {
                // key is invalid or program is already active, skip
                continue;
            }

            // sum up withdrawn amount
            totalWithdrawnAmount += params[i].incentiveAmount;

            RushPoolId id = params[i].key.toId();

            // subtract incentive from pool
            rushPoolIncentiveAmounts[id][incentiveToken] -= params[i].incentiveAmount;

            // subtract incentive from sender
            rushPoolIncentiveDeposits[id][incentiveToken][msgSender] -= params[i].incentiveAmount;
        }

        // transfer incentive tokens to recipient
        if (totalWithdrawnAmount != 0) {
            incentiveToken.safeTransfer(recipient, totalWithdrawnAmount);
        }

        // emit event
        emit WithdrawIncentive(msgSender, incentiveToken, recipient, params, totalWithdrawnAmount);
    }

    /// @inheritdoc IMasterBunni
    function refundIncentive(RushClaimParams[] calldata params, address recipient) external nonReentrant {
        address msgSender = LibMulticaller.senderOrSigner();

        for (uint256 i; i < params.length; i++) {
            address incentiveToken = params[i].incentiveToken;
            uint256 totalRefundAmount;
            for (uint256 j; j < params[i].keys.length; j++) {
                // the program should be over
                RushPoolKey calldata key = params[i].keys[j];
                if (!isValidRushPoolKey(key) || block.timestamp <= key.startTimestamp + key.programLength) {
                    continue;
                }

                // load state
                RushPoolId id = key.toId();
                RushStakeState memory poolState = rushPoolStates[id];
                uint256 incentiveAmount = rushPoolIncentiveDeposits[id][incentiveToken][msgSender]; // the incentives added by msgSender
                if (incentiveAmount == 0) {
                    continue;
                }

                // compute refund amount
                // refund amount is the provided incentive amount minus the reward paid to stakers
                uint256 stakeXTimeUpdated = _computeStakeXTime(
                    key, poolState.stakeXTimeStored, poolState.stakeAmount, poolState.lastStakeAmountUpdateTimestamp
                );
                uint256 rewardAccrued = incentiveAmount.mulDiv(stakeXTimeUpdated, PRECISION);
                uint256 refundAmount = incentiveAmount - rewardAccrued;

                // delete incentive deposit to mark the incentive as refunded
                delete rushPoolIncentiveDeposits[id][incentiveToken][msgSender];

                // accumulate refund amount
                totalRefundAmount += refundAmount;
            }

            // transfer refund amount to recipient
            if (totalRefundAmount != 0) {
                incentiveToken.safeTransfer(recipient, totalRefundAmount);
            }

            // emit event
            emit RefundIncentive(msgSender, incentiveToken, recipient, totalRefundAmount);
        }
    }

    /// @inheritdoc IMasterBunni
    function incentivizeRecurPool(RecurIncentiveParams[] calldata params, address incentiveToken)
        external
        returns (uint256 totalIncentiveAmount)
    {
        address msgSender = LibMulticaller.senderOrSigner();

        for (uint256 i; i < params.length; i++) {
            /// -----------------------------------------------------------------------
            /// Validation
            /// -----------------------------------------------------------------------

            if (params[i].incentiveAmount == 0) continue;

            RecurPoolKey calldata key = params[i].key;
            if (!isValidRecurPoolKey(key)) continue;

            /// -----------------------------------------------------------------------
            /// Storage loads
            /// -----------------------------------------------------------------------

            RecurPoolId id = key.toId();
            RecurPoolState storage state = recurPoolStates[id];
            uint64 lastUpdateTime = state.lastUpdateTime;
            uint64 periodFinish = state.periodFinish;
            uint256 rewardRate = state.rewardRate;
            uint64 lastTimeRewardApplicable = block.timestamp < periodFinish ? uint64(block.timestamp) : periodFinish;

            /// -----------------------------------------------------------------------
            /// State updates
            /// -----------------------------------------------------------------------

            // accrue rewards
            state.rewardPerTokenStored = _rewardPerToken(
                state.rewardPerTokenStored, state.totalSupply, lastTimeRewardApplicable, lastUpdateTime, rewardRate
            );

            // record new reward
            uint256 newRewardRate;
            if (block.timestamp >= periodFinish) {
                // current period is over
                newRewardRate = params[i].incentiveAmount.mulDiv(REWARD_RATE_PRECISION, key.duration);

                state.rewardRate = newRewardRate;
                state.lastUpdateTime = uint64(block.timestamp);
                state.periodFinish = uint64(block.timestamp + key.duration);
            } else {
                // period is still active
                // add the new reward to the existing period
                uint256 remaining = periodFinish - block.timestamp;
                newRewardRate += params[i].incentiveAmount.mulDiv(REWARD_RATE_PRECISION, remaining);

                state.rewardRate = newRewardRate;
                state.lastUpdateTime = uint64(block.timestamp);
            }
            // prevent overflow when computing rewardPerToken
            if (newRewardRate >= ((type(uint256).max / PRECISION_DIV_REWARD_RATE_PRECISION) / key.duration)) {
                revert MasterBunni__AmountTooLarge();
            }

            totalIncentiveAmount += params[i].incentiveAmount;
        }

        // transfer incentive tokens from msgSender to this contract
        if (totalIncentiveAmount != 0) {
            incentiveToken.safeTransferFrom2(msgSender, address(this), totalIncentiveAmount);
        }

        // emit event
        emit IncentivizeRecurPool(msgSender, incentiveToken, params, totalIncentiveAmount);
    }

    /// -----------------------------------------------------------------------
    /// Staker actions
    /// -----------------------------------------------------------------------

    /// @inheritdoc IMasterBunni
    function joinRushPool(RushPoolKey[] calldata keys) external nonReentrant {
        address msgSender = LibMulticaller.senderOrSigner();

        for (uint256 i; i < keys.length; i++) {
            // pool needs to be active
            if (
                !isValidRushPoolKey(keys[i]) || block.timestamp < keys[i].startTimestamp
                    || block.timestamp > keys[i].startTimestamp + keys[i].programLength
            ) {
                continue;
            }

            // msgSender should be locked with address(this) as the unlocker
            if (
                !keys[i].stakeToken.isLocked(msgSender)
                    || keys[i].stakeToken.unlockerOf(msgSender) != IERC20Unlocker(address(this))
            ) {
                continue;
            }

            RushPoolId id = keys[i].toId();
            RushStakeState memory userState = rushPoolUserStates[id][msgSender];
            RushStakeState memory poolState = rushPoolStates[id];
            uint256 remainderStakeAmount = poolState.stakeAmount - userState.stakeAmount; // stake in pool minus the user's existing stake
            uint256 stakeAmountUpdated;
            {
                uint256 balance = ERC20(address(keys[i].stakeToken)).balanceOf(msgSender);
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
            rushPoolUserStates[id][msgSender] = RushStakeState({
                stakeAmount: stakeAmountUpdated,
                stakeXTimeStored: userStakeXTimeUpdated,
                lastStakeAmountUpdateTimestamp: block.timestamp
            });
            if (userState.stakeAmount == 0) {
                // user didn't have any stake in this pool before
                unchecked {
                    ++userPoolCounts[msgSender][keys[i].stakeToken];
                }
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
            rushPoolStates[id] = RushStakeState({
                stakeAmount: remainderStakeAmount + stakeAmountUpdated,
                stakeXTimeStored: poolStakeXTimeUpdated,
                lastStakeAmountUpdateTimestamp: block.timestamp
            });

            // emit event
            emit JoinRushPool(msgSender, keys[i]);
        }
    }

    /// @inheritdoc IMasterBunni
    function exitRushPool(RushPoolKey[] calldata keys) external nonReentrant {
        address msgSender = LibMulticaller.senderOrSigner();

        for (uint256 i; i < keys.length; i++) {
            // should be past pool's start timestamp
            if (!isValidRushPoolKey(keys[i]) || block.timestamp < keys[i].startTimestamp) {
                continue;
            }

            RushPoolId id = keys[i].toId();
            RushStakeState memory userState = rushPoolUserStates[id][msgSender];

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
            rushPoolUserStates[id][msgSender] = RushStakeState({
                stakeAmount: 0,
                stakeXTimeStored: userStakeXTimeUpdated,
                lastStakeAmountUpdateTimestamp: latestActiveTimestamp
            });
            unchecked {
                --userPoolCounts[msgSender][keys[i].stakeToken];
            }

            // update pool state
            RushStakeState memory poolState = rushPoolStates[id];
            uint256 poolStakeXTimeUpdated = _computeStakeXTime(
                keys[i], poolState.stakeXTimeStored, poolState.stakeAmount, poolState.lastStakeAmountUpdateTimestamp
            );
            rushPoolStates[id] = RushStakeState({
                stakeAmount: poolState.stakeAmount - userState.stakeAmount,
                stakeXTimeStored: poolStakeXTimeUpdated,
                lastStakeAmountUpdateTimestamp: latestActiveTimestamp
            });

            // emit event
            emit ExitRushPool(msgSender, keys[i]);
        }
    }

    /// @inheritdoc IMasterBunni
    function joinRecurPool(RecurPoolKey[] calldata keys) external nonReentrant {
        address msgSender = LibMulticaller.senderOrSigner();

        for (uint256 i; i < keys.length; i++) {
            RecurPoolKey calldata key = keys[i];

            /// -----------------------------------------------------------------------
            /// Validation
            /// -----------------------------------------------------------------------

            // key should be valid
            if (!isValidRecurPoolKey(key)) continue;

            // user should have non-zero balance
            uint256 balance = ERC20(address(key.stakeToken)).balanceOf(msgSender);
            if (balance == 0) {
                continue;
            }

            // user's balance should be locked with this contract as the unlocker
            if (
                !key.stakeToken.isLocked(msgSender)
                    || key.stakeToken.unlockerOf(msgSender) != IERC20Unlocker(address(this))
            ) {
                continue;
            }

            /// -----------------------------------------------------------------------
            /// Storage loads
            /// -----------------------------------------------------------------------

            RecurPoolId id = key.toId();
            RecurPoolState storage state = recurPoolStates[id];
            uint256 stakedBalance = state.balanceOf[msgSender];

            // can't stake in a pool twice
            if (balance <= stakedBalance) {
                continue;
            }

            uint64 lastUpdateTime = state.lastUpdateTime;
            uint64 periodFinish = state.periodFinish;
            uint64 lastTimeRewardApplicable = block.timestamp < periodFinish ? uint64(block.timestamp) : periodFinish;
            uint256 totalSupply = state.totalSupply;
            uint256 rewardPerTokenUpdated = _rewardPerToken(
                state.rewardPerTokenStored, totalSupply, lastTimeRewardApplicable, lastUpdateTime, state.rewardRate
            );

            /// -----------------------------------------------------------------------
            /// State updates
            /// -----------------------------------------------------------------------

            // accrue rewards
            state.rewardPerTokenStored = rewardPerTokenUpdated;
            state.lastUpdateTime = lastTimeRewardApplicable;
            state.rewards[msgSender] = _earned(
                state.userRewardPerTokenPaid[msgSender], stakedBalance, rewardPerTokenUpdated, state.rewards[msgSender]
            );
            state.userRewardPerTokenPaid[msgSender] = rewardPerTokenUpdated;

            // stake
            state.totalSupply = totalSupply - stakedBalance + balance;
            state.balanceOf[msgSender] = balance;

            // increment user pool count only if the previous staked balance is 0
            if (stakedBalance == 0) {
                unchecked {
                    ++userPoolCounts[msgSender][key.stakeToken];
                }
            }

            // emit event
            emit JoinRecurPool(msgSender, keys[i]);
        }
    }

    /// @inheritdoc IMasterBunni
    function exitRecurPool(RecurPoolKey[] calldata keys) external nonReentrant {
        address msgSender = LibMulticaller.senderOrSigner();

        for (uint256 i; i < keys.length; i++) {
            RecurPoolKey calldata key = keys[i];

            /// -----------------------------------------------------------------------
            /// Validation
            /// -----------------------------------------------------------------------

            // key should be valid
            if (!isValidRecurPoolKey(key)) continue;

            RecurPoolId id = key.toId();
            RecurPoolState storage state = recurPoolStates[id];
            uint256 stakedBalance = state.balanceOf[msgSender];

            // user should have staked in the pool
            if (stakedBalance == 0) {
                continue;
            }

            /// -----------------------------------------------------------------------
            /// Storage loads
            /// -----------------------------------------------------------------------

            uint64 lastUpdateTime = state.lastUpdateTime;
            uint64 periodFinish = state.periodFinish;
            uint64 lastTimeRewardApplicable = block.timestamp < periodFinish ? uint64(block.timestamp) : periodFinish;
            uint256 totalSupply = state.totalSupply;
            uint256 rewardPerTokenUpdated = _rewardPerToken(
                state.rewardPerTokenStored, totalSupply, lastTimeRewardApplicable, lastUpdateTime, state.rewardRate
            );

            /// -----------------------------------------------------------------------
            /// State updates
            /// -----------------------------------------------------------------------

            // accrue rewards
            state.rewardPerTokenStored = rewardPerTokenUpdated;
            state.lastUpdateTime = lastTimeRewardApplicable;
            state.rewards[msgSender] = _earned(
                state.userRewardPerTokenPaid[msgSender], stakedBalance, rewardPerTokenUpdated, state.rewards[msgSender]
            );
            state.userRewardPerTokenPaid[msgSender] = rewardPerTokenUpdated;

            // remove stake
            delete state.balanceOf[msgSender];
            // total supply has 1:1 relationship with staked amounts
            // so can't ever underflow
            unchecked {
                state.totalSupply = totalSupply - stakedBalance;
            }

            // decrement user pool count
            unchecked {
                --userPoolCounts[msgSender][key.stakeToken];
            }

            // emit event
            emit ExitRecurPool(msgSender, keys[i]);
        }
    }

    /// @inheritdoc IMasterBunni
    function unlock(IERC20Lockable[] calldata stakeTokens) external nonReentrant {
        address msgSender = LibMulticaller.senderOrSigner();

        for (uint256 i; i < stakeTokens.length; i++) {
            // pool count should be 0
            if (userPoolCounts[msgSender][stakeTokens[i]] != 0) {
                continue;
            }

            // address(this) should be the unlocker of msgSender
            // and msgSender should be locked
            if (
                stakeTokens[i].unlockerOf(msgSender) != IERC20Unlocker(address(this))
                    || !stakeTokens[i].isLocked(msgSender)
            ) {
                continue;
            }

            // unlock stake token
            stakeTokens[i].unlock(msgSender);

            // emit event
            emit Unlock(msgSender, stakeTokens[i]);
        }
    }

    /// @inheritdoc IMasterBunni
    function claimRushPool(RushClaimParams[] calldata params, address recipient) external nonReentrant {
        address msgSender = LibMulticaller.senderOrSigner();

        for (uint256 i; i < params.length; i++) {
            address incentiveToken = params[i].incentiveToken;
            uint256 totalClaimableAmount;

            for (uint256 j; j < params[i].keys.length; j++) {
                RushPoolKey calldata key = params[i].keys[j];
                RushPoolId id = key.toId();

                // key should be valid
                if (!isValidRushPoolKey(key)) continue;

                // load state
                RushStakeState memory userState = rushPoolUserStates[id][msgSender];
                uint256 incentiveAmount = rushPoolIncentiveAmounts[id][incentiveToken];
                uint256 rewardPaid = rushPoolUserRewardPaid[id][msgSender][incentiveToken];

                // compute claimable reward
                uint256 stakeXTimeUpdated = _computeStakeXTime(
                    key, userState.stakeXTimeStored, userState.stakeAmount, userState.lastStakeAmountUpdateTimestamp
                );
                uint256 rewardAccrued = incentiveAmount.mulDiv(stakeXTimeUpdated, PRECISION);
                uint256 claimableReward = rewardAccrued - rewardPaid;

                // update claim state
                rushPoolUserRewardPaid[id][msgSender][incentiveToken] = rewardAccrued;

                // accumulate claimable reward
                totalClaimableAmount += claimableReward;
            }

            // transfer incentive tokens to user
            if (totalClaimableAmount != 0) {
                incentiveToken.safeTransfer(recipient, totalClaimableAmount);
            }

            // emit event
            emit ClaimReward(msgSender, incentiveToken, recipient, totalClaimableAmount);
        }
    }

    /// @inheritdoc IMasterBunni
    function claimRecurPool(RecurClaimParams[] calldata params, address recipient) external nonReentrant {
        address msgSender = LibMulticaller.senderOrSigner();

        for (uint256 i; i < params.length; i++) {
            address incentiveToken = params[i].incentiveToken;
            uint256 totalClaimableAmount;

            for (uint256 j; j < params[i].keys.length; j++) {
                RecurPoolKey calldata key = params[i].keys[j];
                RecurPoolId id = key.toId();

                // key should be valid
                if (!isValidRecurPoolKey(key)) continue;

                /// -----------------------------------------------------------------------
                /// Storage loads
                /// -----------------------------------------------------------------------

                // load state
                RecurPoolState storage state = recurPoolStates[id];
                uint64 lastUpdateTime = state.lastUpdateTime;
                uint64 periodFinish = state.periodFinish;
                uint64 lastTimeRewardApplicable =
                    block.timestamp < periodFinish ? uint64(block.timestamp) : periodFinish;
                uint256 rewardPerTokenUpdated = _rewardPerToken(
                    state.rewardPerTokenStored,
                    state.totalSupply,
                    lastTimeRewardApplicable,
                    lastUpdateTime,
                    state.rewardRate
                );

                /// -----------------------------------------------------------------------
                /// State updates
                /// -----------------------------------------------------------------------

                // accrue rewards
                uint256 reward = _earned(
                    state.userRewardPerTokenPaid[msgSender],
                    state.balanceOf[msgSender],
                    rewardPerTokenUpdated,
                    state.rewards[msgSender]
                );
                state.rewardPerTokenStored = rewardPerTokenUpdated;
                state.lastUpdateTime = lastTimeRewardApplicable;
                state.userRewardPerTokenPaid[msgSender] = rewardPerTokenUpdated;

                if (reward != 0) {
                    // delete accrued rewards
                    delete state.rewards[msgSender];

                    // accumulate claimable amount
                    totalClaimableAmount += reward;
                }
            }

            // transfer incentive tokens to user
            if (totalClaimableAmount != 0) {
                incentiveToken.safeTransfer(recipient, totalClaimableAmount);
            }

            // emit event
            emit ClaimReward(msgSender, incentiveToken, recipient, totalClaimableAmount);
        }
    }

    /// -----------------------------------------------------------------------
    /// Getters
    /// -----------------------------------------------------------------------

    /// @inheritdoc IMasterBunni
    function getRushPoolClaimableReward(RushPoolKey calldata key, address user, address incentiveToken)
        external
        view
        returns (uint256 claimableReward)
    {
        // no need to validate key since we just return 0 if it's invalid
        // load state
        RushPoolId id = key.toId();
        RushStakeState memory userState = rushPoolUserStates[id][user];
        uint256 incentiveAmount = rushPoolIncentiveAmounts[id][incentiveToken];
        uint256 rewardPaid = rushPoolUserRewardPaid[id][user][incentiveToken];

        // compute claimable reward
        uint256 stakeXTimeUpdated = _computeStakeXTime(
            key, userState.stakeXTimeStored, userState.stakeAmount, userState.lastStakeAmountUpdateTimestamp
        );
        uint256 rewardAccrued = incentiveAmount.mulDiv(stakeXTimeUpdated, PRECISION);
        return rewardAccrued - rewardPaid;
    }

    /// @inheritdoc IMasterBunni
    function getRecurPoolClaimableReward(RecurPoolKey calldata key, address user)
        external
        view
        returns (uint256 claimableReward)
    {
        // no need to validate key since we just return 0 if it's invalid
        RecurPoolId id = key.toId();
        RecurPoolState storage state = recurPoolStates[id];
        uint64 periodFinish = state.periodFinish;
        uint64 lastTimeRewardApplicable = block.timestamp < periodFinish ? uint64(block.timestamp) : periodFinish;
        uint256 rewardPerTokenUpdated = _rewardPerToken(
            state.rewardPerTokenStored,
            state.totalSupply,
            lastTimeRewardApplicable,
            state.lastUpdateTime,
            state.rewardRate
        );
        return _earned(
            state.userRewardPerTokenPaid[user], state.balanceOf[user], rewardPerTokenUpdated, state.rewards[user]
        );
    }

    /// @inheritdoc IMasterBunni
    function recurPoolStakeBalanceOf(RecurPoolId id, address user) external view returns (uint256) {
        return recurPoolStates[id].balanceOf[user];
    }

    /// @inheritdoc IMasterBunni
    function recurPoolUserRewardPerTokenPaid(RecurPoolId id, address user) external view returns (uint256) {
        return recurPoolStates[id].userRewardPerTokenPaid[user];
    }

    /// @inheritdoc IMasterBunni
    function recurPoolRewards(RecurPoolId id, address user) external view returns (uint256) {
        return recurPoolStates[id].rewards[user];
    }

    /// @inheritdoc IMasterBunni
    function isValidRushPoolKey(RushPoolKey memory key) public pure returns (bool) {
        return address(key.stakeToken) != address(0) && key.stakeCap != 0 && key.startTimestamp != 0
            && key.programLength != 0;
    }

    /// @inheritdoc IMasterBunni
    function isValidRecurPoolKey(RecurPoolKey memory key) public pure returns (bool) {
        return address(key.stakeToken) != address(0) && key.rewardToken != address(0) && key.duration != 0;
    }

    /// -----------------------------------------------------------------------
    /// Callbacks
    /// -----------------------------------------------------------------------

    /// @inheritdoc IERC20Unlocker
    /// @dev Should initialize the user's stake position.
    function lockCallback(address account, uint256 balance, bytes calldata data) external nonReentrant {
        LockCallbackData memory callbackData = abi.decode(data, (LockCallbackData));
        IERC20Lockable stakeToken = IERC20Lockable(msg.sender);

        for (uint256 i; i < callbackData.rushKeys.length; i++) {
            RushPoolKey memory key = callbackData.rushKeys[i];
            uint256 endTimestamp = key.startTimestamp + key.programLength;

            // validate key
            // - key should be valid
            // - pool should be active
            // - stakeToken of key should be msg.sender
            if (
                !isValidRushPoolKey(key) || key.stakeToken != stakeToken || block.timestamp < key.startTimestamp
                    || block.timestamp > endTimestamp
            ) {
                continue;
            }

            RushPoolId id = key.toId();
            uint256 userStakeAmount = rushPoolUserStates[id][account].stakeAmount;
            // can't stake in a pool twice
            if (userStakeAmount != 0) {
                continue;
            }
            RushStakeState memory poolState = rushPoolStates[id];
            uint256 stakeAmount =
                poolState.stakeAmount + balance > key.stakeCap ? key.stakeCap - poolState.stakeAmount : balance;
            // ensure there is capacity left
            if (stakeAmount == 0) {
                continue;
            }

            // update user state
            // leave stakeXTime unchanged since stakeAmount was zero since the last update
            // block.timestamp is at most endTimestamp
            // since we already checked that the program is active
            rushPoolUserStates[id][account].stakeAmount = stakeAmount;
            rushPoolUserStates[id][account].lastStakeAmountUpdateTimestamp = block.timestamp;
            unchecked {
                ++userPoolCounts[account][key.stakeToken];
            }

            // update pool state
            // poolState.lastStakeAmountUpdateTimestamp might be 0 if the pool has never had stakers
            // so we bound it by the start timestamp of the program
            uint256 stakeXTimeUpdated = _computeStakeXTime(
                key,
                poolState.stakeXTimeStored,
                poolState.stakeAmount,
                FixedPointMathLib.max(poolState.lastStakeAmountUpdateTimestamp, key.startTimestamp)
            );
            rushPoolStates[id] = RushStakeState({
                stakeAmount: poolState.stakeAmount + stakeAmount,
                stakeXTimeStored: stakeXTimeUpdated,
                lastStakeAmountUpdateTimestamp: block.timestamp
            });

            // emit event
            emit JoinRushPool(account, key);
        }

        for (uint256 i; i < callbackData.recurKeys.length; i++) {
            RecurPoolKey memory key = callbackData.recurKeys[i];

            // validate key
            // - key should be valid
            // - stakeToken of key should be msg.sender
            if (!isValidRecurPoolKey(key) || key.stakeToken != stakeToken) {
                continue;
            }

            /// -----------------------------------------------------------------------
            /// Storage loads
            /// -----------------------------------------------------------------------

            RecurPoolId id = key.toId();
            RecurPoolState storage state = recurPoolStates[id];
            uint256 stakedBalance = state.balanceOf[account];

            // can't stake in a pool twice
            if (stakedBalance != 0) {
                continue;
            }

            uint64 lastUpdateTime = state.lastUpdateTime;
            uint64 periodFinish = state.periodFinish;
            uint64 lastTimeRewardApplicable = block.timestamp < periodFinish ? uint64(block.timestamp) : periodFinish;
            uint256 totalSupply = state.totalSupply;
            uint256 rewardPerTokenUpdated = _rewardPerToken(
                state.rewardPerTokenStored, totalSupply, lastTimeRewardApplicable, lastUpdateTime, state.rewardRate
            );

            /// -----------------------------------------------------------------------
            /// State updates
            /// -----------------------------------------------------------------------

            // accrue rewards
            // stakedBalance has been 0 so no need to update state.rewards[account]
            state.rewardPerTokenStored = rewardPerTokenUpdated;
            state.lastUpdateTime = lastTimeRewardApplicable;
            state.userRewardPerTokenPaid[account] = rewardPerTokenUpdated;

            // stake
            state.totalSupply = totalSupply + balance;
            state.balanceOf[account] = balance;

            // increment user pool count
            unchecked {
                ++userPoolCounts[account][key.stakeToken];
            }

            // emit event
            emit JoinRecurPool(account, key);
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
            + PRECISION.mulDiv(stakeAmount, key.stakeCap).mulDiv(timeElapsedSinceLastUpdate, key.programLength);
    }

    function _earned(
        uint256 userRewardPerTokenPaid,
        uint256 accountBalance,
        uint256 rewardPerToken,
        uint256 accountRewards
    ) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(accountBalance, rewardPerToken - userRewardPerTokenPaid, PRECISION)
            + accountRewards;
    }

    function _rewardPerToken(
        uint256 rewardPerTokenStored,
        uint256 totalSupply,
        uint256 lastTimeRewardApplicable,
        uint256 lastUpdateTime,
        uint256 rewardRate
    ) internal pure returns (uint256) {
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }
        // mulDiv won't overflow since we check that rewardRate is less than (type(uint256).max / PRECISION_DIV_REWARD_RATE_PRECISION / duration)
        return rewardPerTokenStored
            + FixedPointMathLib.mulDiv(
                (lastTimeRewardApplicable - lastUpdateTime) * PRECISION_DIV_REWARD_RATE_PRECISION, rewardRate, totalSupply
            );
    }
}
