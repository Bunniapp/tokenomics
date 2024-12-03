// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {RushPoolId} from "../types/RushPoolId.sol";
import {RushPoolKey} from "../types/RushPoolKey.sol";
import {RecurPoolId} from "../types/RecurPoolId.sol";
import {RecurPoolKey} from "../types/RecurPoolKey.sol";
import {IERC20Unlocker} from "../external/IERC20Unlocker.sol";
import {IERC20Lockable} from "../external/IERC20Lockable.sol";

/// @title MasterBunni
/// @notice MasterBunni is a contract that incentivizes stakers in multiple pools.
/// It uses stake tokens that are IERC20Lockable.
/// @author zefram.eth
interface IMasterBunni is IERC20Unlocker {
    error MasterBunni__AmountTooLarge();
    error MasterBunni__RewardTooSmall();
    error MasterBunni__InvalidRecipient();

    event DepositIncentive(
        address indexed sender,
        address indexed incentiveToken,
        address indexed recipient,
        RushIncentiveParams[] params,
        uint256 totalIncentiveAmount
    );

    event WithdrawIncentive(
        address indexed sender,
        address indexed incentiveToken,
        address indexed recipient,
        RushIncentiveParams[] params,
        uint256 totalWithdrawnAmount
    );

    event RefundIncentive(
        address indexed sender,
        address indexed incentiveToken,
        address indexed recipient,
        RushPoolKey[] keys,
        uint256 totalRefundAmount
    );

    event IncentivizeRecurPool(
        address indexed sender,
        address indexed incentiveToken,
        RecurIncentiveParams[] params,
        uint256 totalIncentiveAmount
    );

    event JoinRushPool(address indexed sender, RushPoolKey key);

    event ExitRushPool(address indexed sender, RushPoolKey key);

    event JoinRecurPool(address indexed sender, RecurPoolKey key);

    event ExitRecurPool(address indexed sender, RecurPoolKey key);

    event Unlock(address indexed sender, IERC20Lockable indexed stakeToken);

    event ClaimRushPoolReward(
        address indexed sender,
        address indexed incentiveToken,
        address indexed recipient,
        uint256 claimableReward,
        RushPoolKey key
    );

    event ClaimRecurPoolReward(
        address indexed sender,
        address indexed incentiveToken,
        address indexed recipient,
        uint256 reward,
        RecurPoolKey key
    );

    /// @member stakeAmount The amount of stake tokens staked.
    /// @member stakeXTimeStored The cumulativestake x time value since the last stake amount update.
    /// @member lastStakeAmountUpdateTimestamp The timestamp of the last stake amount update in seconds. Must be at most the end timestamp of the program.
    struct RushStakeState {
        uint256 stakeAmount;
        uint256 stakeXTimeStored;
        uint256 lastStakeAmountUpdateTimestamp;
    }

    /// @member lastUpdateTime The last Unix timestamp (in seconds) when rewardPerTokenStored was updated
    /// @member periodFinish The Unix timestamp (in seconds) at which the current reward period ends
    /// @member rewardRate The per-second rate at which rewardPerToken increases
    /// @member rewardPerTokenStored The last stored rewardPerToken value
    /// @member totalSupply The total tokens staked in the pool
    /// @member zeroStakeRewardAccrued The reward distributed during periods where the total stake was zero in the current duration
    /// @member balanceOf The amount of tokens staked by an account
    /// @member userRewardPerTokenPaid The rewardPerToken value when an account last staked/withdrew/withdrew rewards
    /// @member rewards The earned() value when an account last staked/withdrew/withdrew rewards
    struct RecurPoolState {
        uint64 lastUpdateTime;
        uint64 periodFinish;
        uint256 rewardRate;
        uint256 rewardPerTokenStored;
        uint256 totalSupply;
        uint256 zeroStakeRewardAccrued;
        mapping(address => uint256) balanceOf;
        mapping(address => uint256) userRewardPerTokenPaid;
        mapping(address => uint256) rewards;
    }

    /// @member key The RushPoolKey of the RushPool.
    /// @member incentiveAmount The amount of incentive tokens to deposit into the pool.
    struct RushIncentiveParams {
        RushPoolKey key;
        uint256 incentiveAmount;
    }

    /// @member key The RecurPoolKey of the RecurPool.
    /// @member incentiveAmount The amount of incentive tokens to deposit into the pool.
    struct RecurIncentiveParams {
        RecurPoolKey key;
        uint256 incentiveAmount;
    }

    /// @member incentiveToken The incentive token to claim.
    /// @member keys The list of RushPools to claim the incentives for.
    struct RushClaimParams {
        address incentiveToken;
        RushPoolKey[] keys;
    }

    /// @member incentiveToken The incentive token to claim.
    /// @member keys The list of RecurPools to claim the incentives for.
    struct RecurClaimParams {
        address incentiveToken;
        RecurPoolKey[] keys;
    }

    /// @member rushKeys The list of RushPools to stake into.
    /// @member recurKeys The list of RecurPools to stake into.
    struct LockCallbackData {
        RushPoolKey[] rushKeys;
        RecurPoolKey[] recurKeys;
    }

    /// -----------------------------------------------------------------------
    /// Getters
    /// -----------------------------------------------------------------------

    /// @notice Returns the number of incentive pools a user has staked a stake token in.
    /// @dev Used to check if a user can unlock a stake token.
    /// @param user The address of the user.
    /// @param stakeToken The stake token to check.
    /// @return The number of incentive pools a user has staked a stake token in.
    function userPoolCounts(address user, IERC20Lockable stakeToken) external view returns (uint256);

    /// @notice Returns the global stake state of a RushPool.
    /// @param id The RushPoolId of the RushPool.
    /// @return stakeAmount The amount of stake tokens staked.
    /// @return stakeXTimeStored The cumulativestake x time value since the last stake amount update.
    /// @return lastStakeAmountUpdateTimestamp The timestamp of the last stake amount update in seconds. Must be at most the end timestamp of the program.
    function rushPoolStates(RushPoolId id)
        external
        view
        returns (uint256 stakeAmount, uint256 stakeXTimeStored, uint256 lastStakeAmountUpdateTimestamp);

    /// @notice Returns the amount of incentive tokens deposited into a RushPool.
    /// @param id The RushPoolId of the RushPool.
    /// @param incentiveToken The incentive token to check.
    /// @return The amount of incentive tokens deposited into the RushPool.
    function rushPoolIncentiveAmounts(RushPoolId id, address incentiveToken) external view returns (uint256);

    /// @notice Returns the amount of incentive tokens deposited by an address into a RushPool.
    /// @param id The RushPoolId of the RushPool.
    /// @param incentiveToken The incentive token to check.
    /// @param depositor The address to check.
    /// @return The amount of incentive tokens deposited by the address into the RushPool.
    function rushPoolIncentiveDeposits(RushPoolId id, address incentiveToken, address depositor)
        external
        view
        returns (uint256);

    /// @notice Returns the user's stake state in a RushPool.
    /// @param id The RushPoolId of the RushPool.
    /// @param user The address of the user.
    /// @return stakeAmount The amount of stake tokens staked.
    /// @return stakeXTimeStored The cumulativestake x time value since the last stake amount update.
    /// @return lastStakeAmountUpdateTimestamp The timestamp of the last stake amount update in seconds. Must be at most the end timestamp of the program.
    function rushPoolUserStates(RushPoolId id, address user)
        external
        view
        returns (uint256 stakeAmount, uint256 stakeXTimeStored, uint256 lastStakeAmountUpdateTimestamp);

    /// @notice Returns the amount of incentive tokens claimed by a user in a RushPool.
    /// @param id The RushPoolId of the RushPool.
    /// @param user The address of the user.
    /// @param incentiveToken The incentive token to check.
    /// @return The amount of incentive tokens claimed by the user in the RushPool.
    function rushPoolUserRewardPaid(RushPoolId id, address user, address incentiveToken)
        external
        view
        returns (uint256);

    /// @notice Returns the global state of a RecurPool.
    /// @param id The RecurPoolId of the RecurPool.
    /// @return lastUpdateTime The last Unix timestamp (in seconds) when rewardPerTokenStored was updated
    /// @return periodFinish The Unix timestamp (in seconds) at which the current reward period ends
    /// @return rewardRate The per-second rate at which rewardPerToken increases
    /// @return rewardPerTokenStored The last stored rewardPerToken value
    /// @return totalSupply The total tokens staked in the pool
    /// @return zeroStakeRewardAccrued The reward distributed during periods where the total stake was zero in the current duration
    function recurPoolStates(RecurPoolId id)
        external
        view
        returns (
            uint64 lastUpdateTime,
            uint64 periodFinish,
            uint256 rewardRate,
            uint256 rewardPerTokenStored,
            uint256 totalSupply,
            uint256 zeroStakeRewardAccrued
        );

    /// @notice Returns the amount of tokens staked by an address in a RecurPool.
    /// @param id The RecurPoolId of the RecurPool.
    /// @param user The address of the user.
    /// @return The amount of tokens staked by the user in the RecurPool.
    function recurPoolStakeBalanceOf(RecurPoolId id, address user) external view returns (uint256);

    /// @notice Returns the rewardPerTokenPaid value of an address in a RecurPool.
    /// @param id The RecurPoolId of the RecurPool.
    /// @param user The address of the user.
    /// @return The rewardPerTokenPaid value of the user in the RecurPool.
    function recurPoolUserRewardPerTokenPaid(RecurPoolId id, address user) external view returns (uint256);

    /// @notice Returns the accumulated rewards of an address in a RecurPool.
    /// @param id The RecurPoolId of the RecurPool.
    /// @param user The address of the user.
    /// @return The accumulated rewards of the user in the RecurPool.
    function recurPoolRewards(RecurPoolId id, address user) external view returns (uint256);

    /// @notice Returns the amount of claimable reward for a user in a RushPool.
    /// @param key The RushPoolKey of the RushPool.
    /// @param user The address of the user.
    /// @param incentiveToken The incentive token to check.
    /// @return claimableReward The amount of claimable reward for the user in the RushPool.
    function getRushPoolClaimableReward(RushPoolKey calldata key, address user, address incentiveToken)
        external
        view
        returns (uint256 claimableReward);

    /// @notice Returns the amount of claimable reward for a user in a RecurPool.
    /// @param key The RecurPoolKey of the RecurPool.
    /// @param user The address of the user.
    /// @return claimableReward The amount of claimable reward for the user in the RecurPool.
    function getRecurPoolClaimableReward(RecurPoolKey calldata key, address user)
        external
        view
        returns (uint256 claimableReward);

    /// @notice Returns true if the key is valid.
    /// @param key The RushPoolKey or RecurPoolKey to check.
    /// @return isValid True if the key is valid, false otherwise.
    function isValidRushPoolKey(RushPoolKey calldata key) external pure returns (bool isValid);

    /// @notice Returns true if the key is valid.
    /// @param key The RushPoolKey or RecurPoolKey to check.
    /// @return isValid True if the key is valid, false otherwise.
    function isValidRecurPoolKey(RecurPoolKey calldata key) external pure returns (bool isValid);

    /// -----------------------------------------------------------------------
    /// Incentivizer actions
    /// -----------------------------------------------------------------------

    /// @notice Deposits an incentive token to a list of RushPools. Should be called before the RushPools are active.
    /// If one of the RushPools is already active, the incentive will not be pulled from the caller or deposited into the RushPool.
    /// @param params The list of RushPools to deposit the incentive into and the amount to deposit.
    /// @param incentiveToken The incentive token to deposit.
    /// @param recipient The address that will receive the right to withdraw the incentive tokens.
    /// @return totalIncentiveAmount The total amount of incentive tokens deposited.
    function depositIncentive(RushIncentiveParams[] calldata params, address incentiveToken, address recipient)
        external
        returns (uint256 totalIncentiveAmount);

    /// @notice Withdraws an incentive token from a list of RushPools. Should be called before the RushPools are active.
    /// If one of the RushPools is already active, the corresponding incentive will not be withdrawn from.
    /// @param params The list of RushPools to withdraw the incentive from and the amount to withdraw.
    /// @param incentiveToken The incentive token to withdraw.
    /// @param recipient The address that will receive the withdrawn incentive tokens.
    /// @return totalWithdrawnAmount The total amount of incentive tokens withdrawn.
    function withdrawIncentive(RushIncentiveParams[] calldata params, address incentiveToken, address recipient)
        external
        returns (uint256 totalWithdrawnAmount);

    /// @notice Refund unused incentive tokens deposited by msg.sender. Should be called after the RushPools are over.
    /// @param params The list of RushPools to refund the incentive into and the incentive tokens to refund.
    /// @param recipient The address that will receive the refunded incentive tokens.
    function refundIncentive(RushClaimParams[] calldata params, address recipient) external;

    /// @notice Incentivizes a list of RecurPools. Transfers incentive tokens from msgSender to this contract.
    /// @param params The list of RecurPools to incentivize and the incentive amounts.
    /// @param incentiveToken The incentive token to use.
    /// @return totalIncentiveAmount The total incentive amount.
    function incentivizeRecurPool(RecurIncentiveParams[] calldata params, address incentiveToken)
        external
        returns (uint256 totalIncentiveAmount);

    /// -----------------------------------------------------------------------
    /// Staker actions
    /// -----------------------------------------------------------------------

    /// @notice Joins a list of RushPools. Can join a pool where the user has existing stake if more capacity has opened up.
    /// msg.sender should already have locked the stake tokens before calling this function.
    /// @param keys The list of RushPools to join.
    function joinRushPool(RushPoolKey[] calldata keys) external;

    /// @notice Exits a list of RushPools.
    /// @param keys The list of RushPools to exit.
    function exitRushPool(RushPoolKey[] calldata keys) external;

    /// @notice Joins a list of RecurPools. msg.sender should already have locked the stake tokens before calling this function.
    /// @param keys The list of RecurPools to join.
    function joinRecurPool(RecurPoolKey[] calldata keys) external;

    /// @notice Exits a list of RecurPools.
    /// @param keys The list of RecurPools to exit.
    function exitRecurPool(RecurPoolKey[] calldata keys) external;

    /// @notice Unlocks a list of stake tokens that msg.sender has locked.
    /// A stake token is ignored if the user didn't unstake it from all RushPools
    /// or if this contract is not the msg.sender's unlocker.
    /// @param stakeTokens The list of stake tokens to unlock.
    function unlock(IERC20Lockable[] calldata stakeTokens) external;

    /// @notice Claims accrued incentives for a list of RushPools that msg.sender has staked in.
    /// @param params The list of RushPools to claim the incentives for and the incentive tokens to claim.
    /// @param recipient The address that will receive the claimed incentive tokens.
    function claimRushPool(RushClaimParams[] calldata params, address recipient) external;

    /// @notice Claims accrued incentives for a list of RecurPools that msg.sender has staked in.
    /// @param params The list of RecurPools to claim the incentives for and the incentive tokens to claim.
    /// @param recipient The address that will receive the claimed incentive tokens.
    function claimRecurPool(RecurClaimParams[] calldata params, address recipient) external;
}
