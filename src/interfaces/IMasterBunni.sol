// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {RushPoolId} from "../types/RushPoolId.sol";
import {RushPoolKey} from "../types/RushPoolKey.sol";
import {IERC20Unlocker} from "../external/IERC20Unlocker.sol";
import {IERC20Lockable} from "../external/IERC20Lockable.sol";

/// @title MasterBunni
/// @notice MasterBunni is a contract that incentivizes stakers in multiple pools.
/// It uses stake tokens that are IERC20Lockable.
/// @author zefram.eth
interface IMasterBunni is IERC20Unlocker {
    /// @member stakeAmount The amount of stake tokens staked.
    /// @member stakeXTimeStored The cumulativestake x time value since the last stake amount update.
    /// @member lastStakeAmountUpdateTimestamp The timestamp of the last stake amount update in seconds. Must be at most the end timestamp of the program.
    struct StakeState {
        uint256 stakeAmount;
        uint256 stakeXTimeStored;
        uint256 lastStakeAmountUpdateTimestamp;
    }

    /// @member key The RushPoolKey of the RushPool.
    /// @member incentiveAmount The amount of incentive tokens to deposit into the pool.
    struct IncentiveParams {
        RushPoolKey key;
        uint256 incentiveAmount;
    }

    /// @member incentiveToken The incentive token to claim.
    /// @member keys The list of RushPools to claim the incentives for.
    struct ClaimParams {
        address incentiveToken;
        RushPoolKey[] keys;
    }

    /// @member keys The list of RushPools to stake into.
    struct LockCallbackData {
        RushPoolKey[] keys;
    }

    /// @notice Returns the global stake state of a RushPool.
    /// @param id The RushPoolId of the RushPool.
    /// @return stakeAmount The amount of stake tokens staked.
    /// @return stakeXTimeStored The cumulativestake x time value since the last stake amount update.
    /// @return lastStakeAmountUpdateTimestamp The timestamp of the last stake amount update in seconds. Must be at most the end timestamp of the program.
    function poolStates(RushPoolId id)
        external
        view
        returns (uint256 stakeAmount, uint256 stakeXTimeStored, uint256 lastStakeAmountUpdateTimestamp);

    /// @notice Returns the amount of incentive tokens deposited into a RushPool.
    /// @param id The RushPoolId of the RushPool.
    /// @param incentiveToken The incentive token to check.
    /// @return The amount of incentive tokens deposited into the RushPool.
    function incentiveAmounts(RushPoolId id, address incentiveToken) external view returns (uint256);

    /// @notice Returns the amount of incentive tokens deposited by an address into a RushPool.
    /// @param id The RushPoolId of the RushPool.
    /// @param incentiveToken The incentive token to check.
    /// @param depositor The address to check.
    /// @return The amount of incentive tokens deposited by the address into the RushPool.
    function incentiveDeposits(RushPoolId id, address incentiveToken, address depositor)
        external
        view
        returns (uint256);

    /// @notice Returns the user's stake state in a RushPool.
    /// @param id The RushPoolId of the RushPool.
    /// @param user The address of the user.
    /// @return stakeAmount The amount of stake tokens staked.
    /// @return stakeXTimeStored The cumulativestake x time value since the last stake amount update.
    /// @return lastStakeAmountUpdateTimestamp The timestamp of the last stake amount update in seconds. Must be at most the end timestamp of the program.
    function userStates(RushPoolId id, address user)
        external
        view
        returns (uint256 stakeAmount, uint256 stakeXTimeStored, uint256 lastStakeAmountUpdateTimestamp);

    /// @notice Returns the number of incentive pools a user has staked a stake token in.
    /// @dev Used to check if a user can unlock a stake token.
    /// @param user The address of the user.
    /// @param stakeToken The stake token to check.
    /// @return The number of incentive pools a user has staked a stake token in.
    function userPoolCounts(address user, IERC20Lockable stakeToken) external view returns (uint256);

    /// @notice Returns the amount of incentive tokens claimed by a user in a RushPool.
    /// @param id The RushPoolId of the RushPool.
    /// @param user The address of the user.
    /// @param incentiveToken The incentive token to check.
    /// @return The amount of incentive tokens claimed by the user in the RushPool.
    function userRewardPaid(RushPoolId id, address user, address incentiveToken) external view returns (uint256);

    /// @notice Deposits an incentive token to a list of RushPools. Should be called before the RushPools are active.
    /// If one of the RushPools is already active, the incentive will not be pulled from the caller or deposited into the RushPool.
    /// @param params The list of RushPools to deposit the incentive into and the amount to deposit.
    /// @param incentiveToken The incentive token to deposit.
    /// @param recipient The address that will receive the right to withdraw the incentive tokens.
    /// @return totalIncentiveAmount The total amount of incentive tokens deposited.
    function depositIncentive(IncentiveParams[] calldata params, address incentiveToken, address recipient)
        external
        returns (uint256 totalIncentiveAmount);

    /// @notice Withdraws an incentive token from a list of RushPools. Should be called before the RushPools are active.
    /// If one of the RushPools is already active, the corresponding incentive will not be withdrawn from.
    /// @param params The list of RushPools to withdraw the incentive from and the amount to withdraw.
    /// @param incentiveToken The incentive token to withdraw.
    /// @param recipient The address that will receive the withdrawn incentive tokens.
    /// @return totalWithdrawnAmount The total amount of incentive tokens withdrawn.
    function withdrawIncentive(IncentiveParams[] calldata params, address incentiveToken, address recipient)
        external
        returns (uint256 totalWithdrawnAmount);

    /// @notice Refund unused incentive tokens deposited by msg.sender. Should be called after the RushPools are over.
    /// @param params The list of RushPools to refund the incentive into and the incentive tokens to refund.
    /// @param recipient The address that will receive the refunded incentive tokens.
    function refundIncentive(ClaimParams[] calldata params, address recipient) external;

    /// @notice Joins a list of RushPools. Can join a pool where the user has existing stake if more capacity has opened up.
    /// msg.sender should already have locked the stake tokens before calling this function.
    /// @param keys The list of RushPools to join.
    function join(RushPoolKey[] calldata keys) external;

    /// @notice Exits a list of RushPools.
    /// @param keys The list of RushPools to exit.
    function exit(RushPoolKey[] calldata keys) external;

    /// @notice Unlocks a list of stake tokens that msg.sender has locked.
    /// A stake token is ignored if the user didn't unstake it from all RushPools
    /// or if this contract is not the msg.sender's unlocker.
    /// @param stakeTokens The list of stake tokens to unlock.
    function unlock(IERC20Lockable[] calldata stakeTokens) external;

    /// @notice Claims accrued incentives for a list of RushPools that msg.sender has staked in.
    /// @param params The list of RushPools to claim the incentives for and the incentive tokens to claim.
    /// @param recipient The address that will receive the claimed incentive tokens.
    function claim(ClaimParams[] calldata params, address recipient) external;

    /// @notice Returns the amount of claimable reward for a user in a RushPool.
    /// @param key The RushPoolKey of the RushPool.
    /// @param user The address of the user.
    /// @param incentiveToken The incentive token to check.
    /// @return claimableReward The amount of claimable reward for the user in the RushPool.
    function getClaimableReward(RushPoolKey calldata key, address user, address incentiveToken)
        external
        view
        returns (uint256 claimableReward);
}
