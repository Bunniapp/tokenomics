// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import "forge-std/Test.sol";

import {MulticallerEtcher} from "multicaller/MulticallerEtcher.sol";

import "../src/MasterBunni.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {ERC20ReferrerMock} from "./mocks/ERC20ReferrerMock.sol";

contract MasterBunniRecurPoolTest is Test {
    using FixedPointMathLib for *;

    uint256 internal constant PRECISION = 1e36;
    uint256 internal constant REWARD_RATE_PRECISION = 1e6;
    address internal constant RECIPIENT = address(0xB0B);
    uint256 internal constant MAX_REL_ERROR = 1e11;

    IMasterBunni masterBunni;

    function setUp() public {
        vm.warp(1e9);
        masterBunni = new MasterBunni();
        MulticallerEtcher.multicallerWithSender();
        MulticallerEtcher.multicallerWithSigner();
    }

    /// -----------------------------------------------------------------------
    /// Basic tests
    /// -----------------------------------------------------------------------

    function test_recurPool_incentivize_single(uint256 incentiveAmount) public {
        vm.assume(incentiveAmount > 0 && incentiveAmount <= 1e36);

        RecurPoolKey memory key = _createRecurIncentive(incentiveAmount, 7 days);
        RecurPoolId id = key.toId();
        ERC20Mock incentiveToken = ERC20Mock(address(key.rewardToken));

        // check incentive deposit
        assertEq(incentiveToken.balanceOf(address(this)), 0);
        assertEq(incentiveToken.balanceOf(address(masterBunni)), incentiveAmount);

        // check reward rate
        (,, uint256 rewardRate,,) = masterBunni.recurPoolStates(id);
        assertEq(rewardRate, incentiveAmount.mulDiv(REWARD_RATE_PRECISION, key.duration), "Incorrect reward rate");
    }

    function test_recurPool_incentivize_afterPeriodEnd(uint256 incentiveAmount) public {
        vm.assume(incentiveAmount > 0 && incentiveAmount <= 1e36);

        // create incentive
        RecurPoolKey memory key = _createRecurIncentive(incentiveAmount, 7 days);
        RecurPoolId id = key.toId();
        ERC20Mock incentiveToken = ERC20Mock(address(key.rewardToken));

        // wait until the end of the program
        skip(10 days);

        // add incentive again
        incentiveToken.mint(address(this), incentiveAmount);
        IMasterBunni.RecurIncentiveParams[] memory params = new IMasterBunni.RecurIncentiveParams[](1);
        params[0] = IMasterBunni.RecurIncentiveParams({key: key, incentiveAmount: incentiveAmount});
        masterBunni.incentivizeRecurPool(params, address(incentiveToken));

        // check incentive deposit
        assertEq(incentiveToken.balanceOf(address(this)), 0);
        assertEq(incentiveToken.balanceOf(address(masterBunni)), incentiveAmount * 2);

        // check reward rate
        (,, uint256 rewardRate,,) = masterBunni.recurPoolStates(id);
        assertEq(rewardRate, incentiveAmount.mulDiv(REWARD_RATE_PRECISION, key.duration), "Incorrect reward rate");
    }

    function test_recurPool_join_single(
        uint256 incentiveAmount,
        uint256 stakeAmount,
        uint256 duration,
        uint256 stakeTime
    ) public {
        _assumeValidFuzzParams(incentiveAmount, stakeAmount, duration, stakeTime);

        RecurPoolKey memory key = _createRecurIncentive(incentiveAmount, duration);
        ERC20ReferrerMock stakeToken = ERC20ReferrerMock(address(key.stakeToken));

        stakeToken.mint(address(this), stakeAmount, 0);

        // lock stake token
        stakeToken.lock(
            masterBunni,
            abi.encode(
                IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: new RushPoolKey[](0)})
            )
        );

        // join pool
        RecurPoolKey[] memory keys = new RecurPoolKey[](1);
        keys[0] = key;
        masterBunni.joinRecurPool(keys);

        // check updated values
        assertEq(stakeToken.balanceOf(address(this)), stakeAmount);
        assertEq(stakeToken.balanceOf(address(masterBunni)), 0);
        assertEq(masterBunni.userPoolCounts(address(this), stakeToken), 1);
        assertEq(masterBunni.recurPoolStakeBalanceOf(key.toId(), address(this)), stakeAmount);

        // wait some time
        skip(stakeTime);

        // check claimable amount
        uint256 claimableAmount = masterBunni.getRecurPoolClaimableReward(key, address(this));
        uint256 expectedClaimableAmount =
            _expectedRecurReward(incentiveAmount, stakeTime, duration, stakeAmount, stakeAmount);
        if (expectedClaimableAmount - claimableAmount > 1) {
            assertApproxEqRel(claimableAmount, expectedClaimableAmount, MAX_REL_ERROR, "Incorrect claimable amount");
        }

        // claim reward
        IMasterBunni.RecurClaimParams[] memory params = new IMasterBunni.RecurClaimParams[](1);
        params[0].incentiveToken = key.rewardToken;
        params[0].keys = new RecurPoolKey[](1);
        params[0].keys[0] = key;
        masterBunni.claimRecurPool(params, RECIPIENT);

        // check claimed amount
        assertEq(ERC20(key.rewardToken).balanceOf(RECIPIENT), claimableAmount, "Incorrect reward claimed");
    }

    function test_recurPool_exit_single(
        uint256 incentiveAmount,
        uint256 stakeAmount,
        uint256 duration,
        uint256 stakeTime
    ) public {
        _assumeValidFuzzParams(incentiveAmount, stakeAmount, duration, stakeTime);

        RecurPoolKey memory key = _createRecurIncentive(incentiveAmount, duration);
        ERC20ReferrerMock stakeToken = ERC20ReferrerMock(address(key.stakeToken));
        ERC20Mock incentiveToken = ERC20Mock(address(key.rewardToken));
        RecurPoolId id = key.toId();

        stakeToken.mint(address(this), stakeAmount, 0);

        // lock stake token to join the pool
        RecurPoolKey[] memory keys = new RecurPoolKey[](1);
        keys[0] = key;
        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: keys, rushKeys: new RushPoolKey[](0)}))
        );

        // wait some time
        skip(stakeTime);

        // exit the pool
        masterBunni.exitRecurPool(keys);

        // check state
        assertEq(stakeToken.balanceOf(address(this)), stakeAmount);
        assertEq(stakeToken.balanceOf(address(masterBunni)), 0);
        assertEq(masterBunni.userPoolCounts(address(this), stakeToken), 0);
        assertEq(masterBunni.recurPoolStakeBalanceOf(id, address(this)), 0);

        // check claimable amount
        uint256 claimableAmount = masterBunni.getRecurPoolClaimableReward(key, address(this));
        uint256 expectedClaimableAmount =
            _expectedRecurReward(incentiveAmount, stakeTime, duration, stakeAmount, stakeAmount);
        if (expectedClaimableAmount - claimableAmount > 1) {
            assertApproxEqRel(claimableAmount, expectedClaimableAmount, MAX_REL_ERROR, "Incorrect claimable amount");
        }

        // claim reward
        IMasterBunni.RecurClaimParams[] memory params = new IMasterBunni.RecurClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = keys;
        masterBunni.claimRecurPool(params, RECIPIENT);

        // check claimed amount
        assertEq(incentiveToken.balanceOf(RECIPIENT), claimableAmount, "Incorrect reward claimed");

        // unlock stake token
        IERC20Lockable[] memory stakeTokens = new IERC20Lockable[](1);
        stakeTokens[0] = stakeToken;
        masterBunni.unlock(stakeTokens);

        // check unlocked
        assertFalse(stakeToken.isLocked(address(this)));
    }

    function test_recurPool_multipleStakers_differentStakeTimes() public {
        uint256 incentiveAmount = 1000 ether;
        uint256 duration = 10 days;

        RecurPoolKey memory key = _createRecurIncentive(incentiveAmount, duration);
        ERC20ReferrerMock stakeToken = ERC20ReferrerMock(address(key.stakeToken));
        ERC20Mock incentiveToken = ERC20Mock(address(key.rewardToken));

        address staker1 = address(0x1);
        address staker2 = address(0x2);
        address staker3 = address(0x3);

        // Mint stake tokens
        stakeToken.mint(staker1, 400 ether, 0);
        stakeToken.mint(staker2, 300 ether, 0);
        stakeToken.mint(staker3, 300 ether, 0);

        // Staker 1 stakes at the beginning
        vm.startPrank(staker1);
        RecurPoolKey[] memory keys = new RecurPoolKey[](1);
        keys[0] = key;
        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: keys, rushKeys: new RushPoolKey[](0)}))
        );
        vm.stopPrank();

        skip(2 days);

        // Staker 2 stakes after 2 days
        vm.startPrank(staker2);
        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: keys, rushKeys: new RushPoolKey[](0)}))
        );
        vm.stopPrank();

        skip(3 days);

        // Staker 3 stakes after 5 days
        vm.startPrank(staker3);
        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: keys, rushKeys: new RushPoolKey[](0)}))
        );
        vm.stopPrank();

        skip(5 days); // End of program

        // Claim rewards for all stakers
        IMasterBunni.RecurClaimParams[] memory params = new IMasterBunni.RecurClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = keys;

        vm.prank(staker1);
        masterBunni.claimRecurPool(params, staker1);

        vm.prank(staker2);
        masterBunni.claimRecurPool(params, staker2);

        vm.prank(staker3);
        masterBunni.claimRecurPool(params, staker3);

        // Check rewards
        uint256 reward1 = incentiveToken.balanceOf(staker1);
        uint256 reward2 = incentiveToken.balanceOf(staker2);
        uint256 reward3 = incentiveToken.balanceOf(staker3);

        assertApproxEqRel(
            reward1,
            _expectedRecurReward(incentiveAmount, 2 days, duration, 400 ether, 400 ether)
                + _expectedRecurReward(incentiveAmount, 3 days, duration, 400 ether, 700 ether)
                + _expectedRecurReward(incentiveAmount, 5 days, duration, 400 ether, 1000 ether),
            MAX_REL_ERROR,
            "Staker 1 reward incorrect"
        );
        assertApproxEqRel(
            reward2,
            _expectedRecurReward(incentiveAmount, 3 days, duration, 300 ether, 700 ether)
                + _expectedRecurReward(incentiveAmount, 5 days, duration, 300 ether, 1000 ether),
            MAX_REL_ERROR,
            "Staker 2 reward incorrect"
        );
        assertApproxEqRel(
            reward3,
            _expectedRecurReward(incentiveAmount, 5 days, duration, 300 ether, 1000 ether),
            MAX_REL_ERROR,
            "Staker 3 reward incorrect"
        );

        // Check total rewards don't exceed incentive amount
        assertLe(reward1 + reward2 + reward3, incentiveAmount, "Total rewards exceed incentive amount");
    }

    function test_recurPool_multipleStakers_unstakeAndRestake() public {
        uint256 incentiveAmount = 1000 ether;
        uint256 duration = 10 days;

        RecurPoolKey memory key = _createRecurIncentive(incentiveAmount, duration);
        ERC20ReferrerMock stakeToken = ERC20ReferrerMock(address(key.stakeToken));
        ERC20Mock incentiveToken = ERC20Mock(address(key.rewardToken));

        address staker1 = address(0x1);
        address staker2 = address(0x2);

        // Mint stake tokens
        stakeToken.mint(staker1, 500 ether, 0);
        stakeToken.mint(staker2, 500 ether, 0);

        // Both stakers stake at the beginning
        RecurPoolKey[] memory keys = new RecurPoolKey[](1);
        keys[0] = key;

        vm.prank(staker1);
        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: keys, rushKeys: new RushPoolKey[](0)}))
        );

        vm.prank(staker2);
        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: keys, rushKeys: new RushPoolKey[](0)}))
        );

        skip(3 days);

        // Staker 1 exits after 3 days
        vm.prank(staker1);
        masterBunni.exitRecurPool(keys);

        skip(2 days);

        // Staker 1 re-stakes after 2 more days (5 days total)
        vm.prank(staker1);
        masterBunni.joinRecurPool(keys);

        skip(5 days); // End of program

        // Claim rewards for both stakers
        IMasterBunni.RecurClaimParams[] memory params = new IMasterBunni.RecurClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = keys;

        vm.prank(staker1);
        masterBunni.claimRecurPool(params, staker1);

        vm.prank(staker2);
        masterBunni.claimRecurPool(params, staker2);

        // Check rewards
        uint256 reward1 = incentiveToken.balanceOf(staker1);
        uint256 reward2 = incentiveToken.balanceOf(staker2);

        uint256 expectedReward1 = _expectedRecurReward(incentiveAmount, 3 days, duration, 500 ether, 1000 ether)
            + _expectedRecurReward(incentiveAmount, 5 days, duration, 500 ether, 1000 ether);
        uint256 expectedReward2 = _expectedRecurReward(incentiveAmount, 3 days, duration, 500 ether, 1000 ether)
            + _expectedRecurReward(incentiveAmount, 2 days, duration, 500 ether, 500 ether)
            + _expectedRecurReward(incentiveAmount, 5 days, duration, 500 ether, 1000 ether);

        assertApproxEqRel(reward1, expectedReward1, MAX_REL_ERROR, "Staker 1 reward incorrect");
        assertApproxEqRel(reward2, expectedReward2, MAX_REL_ERROR, "Staker 2 reward incorrect");

        // Check total rewards don't exceed incentive amount
        assertLe(reward1 + reward2, incentiveAmount, "Total rewards exceed incentive amount");
    }

    function test_recurPool_multipleOperations() public {
        uint256 incentiveAmount = 1000 ether;
        uint256 duration = 10 days;

        RecurPoolKey memory key = _createRecurIncentive(incentiveAmount, duration);
        ERC20ReferrerMock stakeToken = ERC20ReferrerMock(address(key.stakeToken));
        ERC20Mock incentiveToken = ERC20Mock(address(key.rewardToken));
        RecurPoolId id = key.toId();

        address staker1 = address(0x1234);
        address staker2 = address(0x5678);
        uint256 stakeAmount = 100 ether;

        // Mint stake tokens for both stakers
        stakeToken.mint(staker1, stakeAmount, 0);
        stakeToken.mint(staker2, stakeAmount, 0);

        vm.startPrank(staker1);
        stakeToken.lock(
            masterBunni,
            abi.encode(
                IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](1), rushKeys: new RushPoolKey[](0)})
            )
        );
        vm.stopPrank();

        vm.startPrank(staker2);
        stakeToken.lock(
            masterBunni,
            abi.encode(
                IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](1), rushKeys: new RushPoolKey[](0)})
            )
        );
        vm.stopPrank();

        RecurPoolKey[] memory keys = new RecurPoolKey[](1);
        keys[0] = key;

        // Both stakers join the pool
        vm.prank(staker1);
        masterBunni.joinRecurPool(keys);

        vm.prank(staker2);
        masterBunni.joinRecurPool(keys);

        skip(5 days);

        // Staker1 exits from the pool
        vm.prank(staker1);
        masterBunni.exitRecurPool(keys);

        skip(5 days); // End of program

        // Both stakers claim rewards
        IMasterBunni.RecurClaimParams[] memory claimParams = new IMasterBunni.RecurClaimParams[](1);
        claimParams[0].incentiveToken = address(incentiveToken);
        claimParams[0].keys = keys;

        vm.prank(staker1);
        masterBunni.claimRecurPool(claimParams, staker1);

        vm.prank(staker2);
        masterBunni.claimRecurPool(claimParams, staker2);

        // Staker2 exits from the pool
        vm.prank(staker2);
        masterBunni.exitRecurPool(keys);

        // Unlock stake tokens for both stakers
        IERC20Lockable[] memory stakeTokens = new IERC20Lockable[](1);
        stakeTokens[0] = stakeToken;

        vm.prank(staker1);
        masterBunni.unlock(stakeTokens);

        vm.prank(staker2);
        masterBunni.unlock(stakeTokens);

        // Verify final states
        assertEq(masterBunni.recurPoolStakeBalanceOf(id, staker1), 0, "Staker1 balance should be zero");
        assertEq(masterBunni.recurPoolStakeBalanceOf(id, staker2), 0, "Staker2 balance should be zero");

        assertEq(masterBunni.userPoolCounts(staker1, stakeToken), 0, "Staker1 pool count should be zero");
        assertEq(masterBunni.userPoolCounts(staker2, stakeToken), 0, "Staker2 pool count should be zero");

        assertFalse(stakeToken.isLocked(staker1), "Staker1 stake token should be unlocked");
        assertFalse(stakeToken.isLocked(staker2), "Staker2 stake token should be unlocked");

        uint256 reward1 = incentiveToken.balanceOf(staker1);
        uint256 reward2 = incentiveToken.balanceOf(staker2);

        uint256 expectedReward1 = _expectedRecurReward(incentiveAmount, 5 days, duration, stakeAmount, 2 * stakeAmount);
        uint256 expectedReward2 = _expectedRecurReward(incentiveAmount, 5 days, duration, stakeAmount, 2 * stakeAmount)
            + _expectedRecurReward(incentiveAmount, 5 days, duration, stakeAmount, stakeAmount);

        assertApproxEqRel(reward1, expectedReward1, MAX_REL_ERROR, "Staker1 reward incorrect");
        assertApproxEqRel(reward2, expectedReward2, MAX_REL_ERROR, "Staker2 reward incorrect");

        // Check total rewards don't exceed incentive amount
        assertLe(reward1 + reward2, incentiveAmount, "Total rewards exceed incentive amount");
    }

    /// -----------------------------------------------------------------------
    /// Edge case tests
    /// -----------------------------------------------------------------------

    function test_recurPool_incentivize_ZeroAmount() public {
        ERC20ReferrerMock stakeToken = new ERC20ReferrerMock();
        ERC20Mock incentiveToken = new ERC20Mock();

        RecurPoolKey memory key =
            RecurPoolKey({stakeToken: stakeToken, rewardToken: address(incentiveToken), duration: 7 days});

        IMasterBunni.RecurIncentiveParams[] memory params = new IMasterBunni.RecurIncentiveParams[](1);
        params[0] = IMasterBunni.RecurIncentiveParams({key: key, incentiveAmount: 0});

        uint256 depositedAmount = masterBunni.incentivizeRecurPool(params, address(incentiveToken));
        assertEq(depositedAmount, 0, "Should not deposit zero amount");
    }

    function test_recurPool_incentivize_ExistingRewards() public {
        uint256 initialIncentive = 1000 ether;
        uint256 additionalIncentive = 500 ether;
        uint256 duration = 6 days;

        RecurPoolKey memory key = _createRecurIncentive(initialIncentive, duration);
        RecurPoolId id = key.toId();
        ERC20Mock incentiveToken = ERC20Mock(address(key.rewardToken));

        skip(3 days);

        IMasterBunni.RecurIncentiveParams[] memory params = new IMasterBunni.RecurIncentiveParams[](1);
        params[0] = IMasterBunni.RecurIncentiveParams({key: key, incentiveAmount: additionalIncentive});

        incentiveToken.mint(address(this), additionalIncentive);
        incentiveToken.approve(address(masterBunni), additionalIncentive);

        masterBunni.incentivizeRecurPool(params, address(incentiveToken));

        (,, uint256 rewardRate,,) = masterBunni.recurPoolStates(id);
        uint256 expectedRewardRate =
            (initialIncentive / 2 + additionalIncentive).mulDiv(REWARD_RATE_PRECISION, duration);
        assertApproxEqRel(
            rewardRate, expectedRewardRate, MAX_REL_ERROR, "Incorrect reward rate after additional incentive"
        );
    }

    function test_recurPool_incentivize_IncentiveTokenMismatch() public {
        // create incentive key
        ERC20ReferrerMock stakeToken = new ERC20ReferrerMock();
        ERC20Mock incentiveToken = new ERC20Mock();
        ERC20Mock incentiveToken2 = new ERC20Mock();
        RecurPoolKey memory key =
            RecurPoolKey({stakeToken: stakeToken, rewardToken: address(incentiveToken), duration: 7 days});

        // mint and approve incentive tokens
        incentiveToken.mint(address(this), 1000 ether);
        incentiveToken.approve(address(masterBunni), 1000 ether);
        incentiveToken2.mint(address(this), 1000 ether);
        incentiveToken2.approve(address(masterBunni), 1000 ether);

        // try incentivizing key with different incentive token
        vm.record();
        IMasterBunni.RecurIncentiveParams[] memory params = new IMasterBunni.RecurIncentiveParams[](1);
        params[0] = IMasterBunni.RecurIncentiveParams({key: key, incentiveAmount: 1000 ether});
        masterBunni.incentivizeRecurPool(params, address(incentiveToken2));
        (, bytes32[] memory writeSlots) = vm.accesses(address(masterBunni));
        assertEq(writeSlots.length, 0, "Should not update state");
        assertEq(incentiveToken.balanceOf(address(this)), 1000 ether, "Should not incentivize");
        assertEq(incentiveToken2.balanceOf(address(this)), 1000 ether, "Should not incentivize");
    }

    function test_recurPool_join_ZeroBalance() public {
        RecurPoolKey memory key = _createRecurIncentive(1000 ether, 7 days);
        RecurPoolId id = key.toId();

        RecurPoolKey[] memory keys = new RecurPoolKey[](1);
        keys[0] = key;

        masterBunni.joinRecurPool(keys);

        assertEq(masterBunni.recurPoolStakeBalanceOf(id, address(this)), 0, "Should not join with zero balance");
    }

    function test_recurPool_exit_NotStaked() public {
        RecurPoolKey memory key = _createRecurIncentive(1000 ether, 7 days);

        RecurPoolKey[] memory keys = new RecurPoolKey[](1);
        keys[0] = key;

        // No revert expected, but no state change should occur
        vm.record();
        masterBunni.exitRecurPool(keys);
        (, bytes32[] memory writeSlots) = vm.accesses(address(masterBunni));
        assertEq(writeSlots.length, 0, "Should not update state");
    }

    function test_recurPool_claim_NoReward() public {
        RecurPoolKey memory key = _createRecurIncentive(1000 ether, 7 days);
        ERC20ReferrerMock stakeToken = ERC20ReferrerMock(address(key.stakeToken));
        ERC20Mock incentiveToken = ERC20Mock(address(key.rewardToken));

        stakeToken.mint(address(this), 500 ether, 0);

        RecurPoolKey[] memory keys = new RecurPoolKey[](1);
        keys[0] = key;

        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: keys, rushKeys: new RushPoolKey[](0)}))
        );

        masterBunni.joinRecurPool(keys);

        IMasterBunni.RecurClaimParams[] memory params = new IMasterBunni.RecurClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = keys;

        masterBunni.claimRecurPool(params, RECIPIENT);

        assertEq(incentiveToken.balanceOf(RECIPIENT), 0, "Should not claim any reward immediately after staking");
    }

    function test_unlock_StillStaked() public {
        RecurPoolKey memory key = _createRecurIncentive(1000 ether, 7 days);
        ERC20ReferrerMock stakeToken = ERC20ReferrerMock(address(key.stakeToken));

        stakeToken.mint(address(this), 500 ether, 0);

        RecurPoolKey[] memory keys = new RecurPoolKey[](1);
        keys[0] = key;

        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: keys, rushKeys: new RushPoolKey[](0)}))
        );

        masterBunni.joinRecurPool(keys);

        IERC20Lockable[] memory stakeTokens = new IERC20Lockable[](1);
        stakeTokens[0] = stakeToken;

        masterBunni.unlock(stakeTokens);

        assertTrue(stakeToken.isLocked(address(this)), "Should not unlock while still staked");
    }

    /// -----------------------------------------------------------------------
    /// Internal utilities
    /// -----------------------------------------------------------------------

    function _assumeValidFuzzParams(uint256 incentiveAmount, uint256 stakeAmount, uint256 duration, uint256 stakeTime)
        internal
        pure
    {
        vm.assume(
            incentiveAmount >= 1e6 && incentiveAmount <= 1e36 && stakeAmount > 0 && stakeAmount <= 1e36 && duration > 0
                && duration < 365 days && stakeTime > 0 && stakeTime <= duration
        );
    }

    function _createRecurIncentive(uint256 incentiveAmount, uint256 duration)
        internal
        returns (RecurPoolKey memory key)
    {
        ERC20ReferrerMock stakeToken = new ERC20ReferrerMock();

        // mint incentive token
        ERC20Mock incentiveToken = new ERC20Mock();
        incentiveToken.mint(address(this), incentiveAmount);

        // approve incentive token to MasterBunni
        incentiveToken.approve(address(masterBunni), type(uint256).max);

        // deposit incentive
        key = RecurPoolKey({stakeToken: stakeToken, rewardToken: address(incentiveToken), duration: duration});
        IMasterBunni.RecurIncentiveParams[] memory params = new IMasterBunni.RecurIncentiveParams[](1);
        params[0] = IMasterBunni.RecurIncentiveParams({key: key, incentiveAmount: incentiveAmount});
        masterBunni.incentivizeRecurPool(params, address(incentiveToken));
    }

    function _expectedRecurReward(
        uint256 incentiveAmount,
        uint256 stakeTime,
        uint256 duration,
        uint256 stakeAmount,
        uint256 totalSupply
    ) internal pure returns (uint256) {
        return incentiveAmount.mulDiv(stakeTime, duration).mulDiv(stakeAmount, totalSupply);
    }
}
