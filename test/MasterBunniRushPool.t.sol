// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import "forge-std/Test.sol";

import {MulticallerEtcher} from "multicaller/MulticallerEtcher.sol";

import "../src/MasterBunni.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {ERC20ReferrerMock} from "./mocks/ERC20ReferrerMock.sol";

contract MasterBunniRushPoolTest is Test {
    using FixedPointMathLib for *;

    uint256 internal constant PRECISION = 1e36;
    address internal constant RECIPIENT = address(0xB0B);
    uint256 internal constant MAX_REL_ERROR = 1e3;

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

    function test_rushPool_depositIncentive_single(uint256 incentiveAmount) public {
        vm.assume(incentiveAmount > 0);

        (, RushPoolId id,, ERC20Mock incentiveToken) =
            _createIncentive(incentiveAmount, 1000 ether, block.timestamp + 3 days, 7 days);

        // check incentive deposit
        assertEq(incentiveToken.balanceOf(address(this)), 0);
        assertEq(incentiveToken.balanceOf(address(masterBunni)), incentiveAmount);
        assertEq(masterBunni.rushPoolIncentiveAmounts(id, address(incentiveToken)), incentiveAmount);
        assertEq(masterBunni.rushPoolIncentiveDeposits(id, address(incentiveToken), address(this)), incentiveAmount);
    }

    function test_rushPool_withdrawIncentive_single(uint256 incentiveAmount) public {
        vm.assume(incentiveAmount > 0);

        (RushPoolKey memory key, RushPoolId id,, ERC20Mock incentiveToken) =
            _createIncentive(incentiveAmount, 1000 ether, block.timestamp + 3 days, 7 days);

        // withdraw incentive
        IMasterBunni.RushIncentiveParams[] memory params = new IMasterBunni.RushIncentiveParams[](1);
        params[0] = IMasterBunni.RushIncentiveParams({key: key, incentiveAmount: incentiveAmount});
        masterBunni.withdrawIncentive(params, address(incentiveToken), RECIPIENT);

        // check incentive withdrawal
        assertEq(incentiveToken.balanceOf(RECIPIENT), incentiveAmount);
        assertEq(incentiveToken.balanceOf(address(masterBunni)), 0);
        assertEq(masterBunni.rushPoolIncentiveAmounts(id, address(incentiveToken)), 0);
        assertEq(masterBunni.rushPoolIncentiveDeposits(id, address(incentiveToken), address(this)), 0);
    }

    function test_rushPool_refundIncentive(
        uint256 incentiveAmount,
        uint256 stakeCap,
        uint256 stakeAmount,
        uint256 programLength
    ) public {
        _assumeValidFuzzParams(incentiveAmount, stakeCap, stakeAmount, programLength, 1);

        (RushPoolKey memory key, RushPoolId id, ERC20ReferrerMock stakeToken, ERC20Mock incentiveToken) =
            _createIncentive(incentiveAmount, stakeCap, block.timestamp + 1, programLength);
        skip(1); // start program

        // mint stake token
        stakeToken.mint(address(this), stakeAmount, 0);

        // lock stake token to join the pool
        {
            RushPoolKey[] memory keys = new RushPoolKey[](1);
            keys[0] = key;
            stakeToken.lock(
                masterBunni,
                abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
            );
        }

        // wait until the end of the program
        skip(programLength + 1);

        // check claimable amount
        uint256 claimableAmount = masterBunni.getRushPoolClaimableReward(key, address(this), address(incentiveToken));
        assertEq(claimableAmount, _expectedReward(key, incentiveAmount, programLength, stakeAmount));

        // claim reward
        IMasterBunni.RushClaimParams[] memory params = new IMasterBunni.RushClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = new RushPoolKey[](1);
        params[0].keys[0] = key;
        masterBunni.claimRushPool(params, RECIPIENT);

        // check claimed amount
        assertEq(incentiveToken.balanceOf(RECIPIENT), claimableAmount);
        assertEq(masterBunni.rushPoolUserRewardPaid(id, address(this), address(incentiveToken)), claimableAmount);

        // get refund
        address refundRecipient = address(0x666);
        IMasterBunni.RushClaimParams[] memory refundParams = new IMasterBunni.RushClaimParams[](1);
        refundParams[0].incentiveToken = address(incentiveToken);
        refundParams[0].keys = new RushPoolKey[](1);
        refundParams[0].keys[0] = key;
        masterBunni.refundIncentive(refundParams, refundRecipient);

        // check refund amount
        assertEq(incentiveToken.balanceOf(refundRecipient), incentiveAmount - claimableAmount);
    }

    function test_rushPool_join_single_viaLock(
        uint256 incentiveAmount,
        uint256 stakeCap,
        uint256 stakeAmount,
        uint256 programLength,
        uint256 stakeTime
    ) public {
        _assumeValidFuzzParams(incentiveAmount, stakeCap, stakeAmount, programLength, stakeTime);

        (RushPoolKey memory key, RushPoolId id, ERC20ReferrerMock stakeToken, ERC20Mock incentiveToken) =
            _createIncentive(incentiveAmount, stakeCap, block.timestamp + 1, programLength);
        skip(1); // start program

        // mint stake token
        stakeToken.mint(address(this), stakeAmount, 0);

        // lock stake token to join the pool
        {
            RushPoolKey[] memory keys = new RushPoolKey[](1);
            keys[0] = key;
            stakeToken.lock(
                masterBunni,
                abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
            );
        }

        // check updated values
        {
            (uint256 poolStakeAmount, uint256 poolStakeXTimeStored, uint256 poolLastStakeAmountUpdateTimestamp) =
                masterBunni.rushPoolStates(id);
            (uint256 userStakeAmount, uint256 userStakeXTimeStored, uint256 userLastStakeAmountUpdateTimestamp) =
                masterBunni.rushPoolUserStates(id, address(this));
            assertEq(stakeToken.balanceOf(address(this)), stakeAmount);
            assertEq(stakeToken.balanceOf(address(masterBunni)), 0);
            assertEq(masterBunni.userPoolCounts(address(this), stakeToken), 1);
            assertEq(poolStakeAmount, stakeAmount);
            assertEq(poolStakeXTimeStored, 0);
            assertEq(poolLastStakeAmountUpdateTimestamp, block.timestamp);
            assertEq(userStakeAmount, stakeAmount);
            assertEq(userStakeXTimeStored, 0);
            assertEq(userLastStakeAmountUpdateTimestamp, block.timestamp);
            assertEq(masterBunni.rushPoolUserRewardPaid(id, address(this), address(incentiveToken)), 0);
        }

        // wait some time
        skip(stakeTime);

        // check claimable amount
        uint256 claimableAmount = masterBunni.getRushPoolClaimableReward(key, address(this), address(incentiveToken));
        assertEq(claimableAmount, _expectedReward(key, incentiveAmount, stakeTime, stakeAmount));

        // claim reward
        IMasterBunni.RushClaimParams[] memory params = new IMasterBunni.RushClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = new RushPoolKey[](1);
        params[0].keys[0] = key;
        masterBunni.claimRushPool(params, RECIPIENT);

        // check claimed amount
        assertEq(incentiveToken.balanceOf(RECIPIENT), claimableAmount);
        assertEq(masterBunni.rushPoolUserRewardPaid(id, address(this), address(incentiveToken)), claimableAmount);
    }

    function test_rushPool_join_single(
        uint256 incentiveAmount,
        uint256 stakeCap,
        uint256 stakeAmount,
        uint256 programLength,
        uint256 stakeTime
    ) public {
        _assumeValidFuzzParams(incentiveAmount, stakeCap, stakeAmount, programLength, stakeTime);

        (RushPoolKey memory key, RushPoolId id, ERC20ReferrerMock stakeToken, ERC20Mock incentiveToken) =
            _createIncentive(incentiveAmount, stakeCap, block.timestamp + 1, programLength);
        skip(1); // start program

        // mint stake token
        stakeToken.mint(address(this), stakeAmount, 0);

        // lock stake token
        stakeToken.lock(
            masterBunni,
            abi.encode(
                IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: new RushPoolKey[](0)})
            )
        );

        // join pool
        {
            RushPoolKey[] memory keys = new RushPoolKey[](1);
            keys[0] = key;
            masterBunni.joinRushPool(keys);
        }

        // check updated values
        {
            (uint256 poolStakeAmount, uint256 poolStakeXTimeStored, uint256 poolLastStakeAmountUpdateTimestamp) =
                masterBunni.rushPoolStates(id);
            (uint256 userStakeAmount, uint256 userStakeXTimeStored, uint256 userLastStakeAmountUpdateTimestamp) =
                masterBunni.rushPoolUserStates(id, address(this));
            assertEq(stakeToken.balanceOf(address(this)), stakeAmount);
            assertEq(stakeToken.balanceOf(address(masterBunni)), 0);
            assertEq(masterBunni.userPoolCounts(address(this), stakeToken), 1);
            assertEq(poolStakeAmount, stakeAmount);
            assertEq(poolStakeXTimeStored, 0);
            assertEq(poolLastStakeAmountUpdateTimestamp, block.timestamp);
            assertEq(userStakeAmount, stakeAmount);
            assertEq(userStakeXTimeStored, 0);
            assertEq(userLastStakeAmountUpdateTimestamp, block.timestamp);
            assertEq(masterBunni.rushPoolUserRewardPaid(id, address(this), address(incentiveToken)), 0);
        }

        // wait some time
        skip(stakeTime);

        // check claimable amount
        uint256 claimableAmount = masterBunni.getRushPoolClaimableReward(key, address(this), address(incentiveToken));
        assertEq(claimableAmount, _expectedReward(key, incentiveAmount, stakeTime, stakeAmount));

        // claim reward
        IMasterBunni.RushClaimParams[] memory params = new IMasterBunni.RushClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = new RushPoolKey[](1);
        params[0].keys[0] = key;
        masterBunni.claimRushPool(params, RECIPIENT);

        // check claimed amount
        assertEq(incentiveToken.balanceOf(RECIPIENT), claimableAmount);
        assertEq(masterBunni.rushPoolUserRewardPaid(id, address(this), address(incentiveToken)), claimableAmount);
    }

    function test_rushPool_exit_single(
        uint256 incentiveAmount,
        uint256 stakeCap,
        uint256 stakeAmount,
        uint256 programLength,
        uint256 stakeTime
    ) public {
        _assumeValidFuzzParams(incentiveAmount, stakeCap, stakeAmount, programLength, stakeTime);

        (RushPoolKey memory key, RushPoolId id, ERC20ReferrerMock stakeToken, ERC20Mock incentiveToken) =
            _createIncentive(incentiveAmount, stakeCap, block.timestamp + 1, programLength);
        skip(1); // start program

        // mint stake token
        stakeToken.mint(address(this), stakeAmount, 0);

        // lock stake token to join the pool
        RushPoolKey[] memory keys = new RushPoolKey[](1);
        keys[0] = key;
        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
        );

        // wait some time
        skip(stakeTime);

        // exit the pool
        masterBunni.exitRushPool(keys);

        // check state
        {
            (uint256 poolStakeAmount, uint256 poolStakeXTimeStored, uint256 poolLastStakeAmountUpdateTimestamp) =
                masterBunni.rushPoolStates(id);
            (uint256 userStakeAmount, uint256 userStakeXTimeStored, uint256 userLastStakeAmountUpdateTimestamp) =
                masterBunni.rushPoolUserStates(id, address(this));
            assertEq(stakeToken.balanceOf(address(this)), stakeAmount);
            assertEq(stakeToken.balanceOf(address(masterBunni)), 0);
            assertEq(masterBunni.userPoolCounts(address(this), stakeToken), 0);
            assertEq(poolStakeAmount, 0);
            assertEq(poolStakeXTimeStored, _expectedStakeXTime(key, stakeTime, stakeAmount));
            assertEq(poolLastStakeAmountUpdateTimestamp, block.timestamp);
            assertEq(userStakeAmount, 0);
            assertEq(userStakeXTimeStored, _expectedStakeXTime(key, stakeTime, stakeAmount));
            assertEq(userLastStakeAmountUpdateTimestamp, block.timestamp);
            assertEq(masterBunni.rushPoolUserRewardPaid(id, address(this), address(incentiveToken)), 0);
        }

        // wait some time
        skip(stakeTime);

        // check claimable amount
        uint256 claimableAmount = masterBunni.getRushPoolClaimableReward(key, address(this), address(incentiveToken));
        assertEq(claimableAmount, _expectedReward(key, incentiveAmount, stakeTime, stakeAmount));

        // claim reward
        IMasterBunni.RushClaimParams[] memory params = new IMasterBunni.RushClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = new RushPoolKey[](1);
        params[0].keys[0] = key;
        masterBunni.claimRushPool(params, RECIPIENT);

        // check claimed amount
        assertEq(incentiveToken.balanceOf(RECIPIENT), claimableAmount);
        assertEq(masterBunni.rushPoolUserRewardPaid(id, address(this), address(incentiveToken)), claimableAmount);

        // unlock stake token
        IERC20Lockable[] memory stakeTokens = new IERC20Lockable[](1);
        stakeTokens[0] = stakeToken;
        masterBunni.unlock(stakeTokens);

        // check unlocked
        assertFalse(stakeToken.isLocked(address(this)));
    }

    function test_rushPool_multipleStakers_differentStakeTimes() public {
        uint256 incentiveAmount = 1000 ether;
        uint256 stakeCap = 1000 ether;
        uint256 programLength = 10 days;

        (RushPoolKey memory key,, ERC20ReferrerMock stakeToken, ERC20Mock incentiveToken) =
            _createIncentive(incentiveAmount, stakeCap, block.timestamp + 1, programLength);
        skip(1); // start program

        address staker1 = address(0x1);
        address staker2 = address(0x2);
        address staker3 = address(0x3);

        // Mint and approve stake tokens
        stakeToken.mint(staker1, 400 ether, 0);
        stakeToken.mint(staker2, 300 ether, 0);
        stakeToken.mint(staker3, 300 ether, 0);

        vm.startPrank(staker1);
        stakeToken.approve(address(masterBunni), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(staker2);
        stakeToken.approve(address(masterBunni), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(staker3);
        stakeToken.approve(address(masterBunni), type(uint256).max);
        vm.stopPrank();

        // Staker 1 stakes at the beginning
        vm.startPrank(staker1);
        RushPoolKey[] memory keys = new RushPoolKey[](1);
        keys[0] = key;
        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
        );
        vm.stopPrank();

        skip(2 days);

        // Staker 2 stakes after 2 days
        vm.startPrank(staker2);
        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
        );
        vm.stopPrank();

        skip(3 days);

        // Staker 3 stakes after 5 days
        vm.startPrank(staker3);
        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
        );
        vm.stopPrank();

        skip(5 days); // End of program

        // Claim rewards for all stakers
        IMasterBunni.RushClaimParams[] memory params = new IMasterBunni.RushClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = keys;

        vm.prank(staker1);
        masterBunni.claimRushPool(params, staker1);

        vm.prank(staker2);
        masterBunni.claimRushPool(params, staker2);

        vm.prank(staker3);
        masterBunni.claimRushPool(params, staker3);

        // Check rewards
        uint256 reward1 = incentiveToken.balanceOf(staker1);
        uint256 reward2 = incentiveToken.balanceOf(staker2);
        uint256 reward3 = incentiveToken.balanceOf(staker3);
        assertApproxEqRel(
            reward1,
            _expectedReward(key, incentiveAmount, programLength, 400 ether),
            MAX_REL_ERROR,
            "Staker 1 reward incorrect"
        );
        assertApproxEqRel(
            reward2,
            _expectedReward(key, incentiveAmount, (programLength - 2 days), 300 ether),
            MAX_REL_ERROR,
            "Staker 2 reward incorrect"
        );
        assertApproxEqRel(
            reward3,
            _expectedReward(key, incentiveAmount, (programLength - 5 days), 300 ether),
            MAX_REL_ERROR,
            "Staker 3 reward incorrect"
        );

        // Get refund
        skip(1); // skip past program end
        address refundRecipient = address(0x666);
        masterBunni.refundIncentive(params, refundRecipient);

        // Check refund amount
        assertEq(incentiveToken.balanceOf(refundRecipient), incentiveAmount - reward1 - reward2 - reward3);
    }

    function test_rushPool_multipleStakers_unstakeAndRestake() public {
        uint256 incentiveAmount = 1000 ether;
        uint256 stakeCap = 1000 ether;
        uint256 programLength = 10 days;

        (RushPoolKey memory key,, ERC20ReferrerMock stakeToken, ERC20Mock incentiveToken) =
            _createIncentive(incentiveAmount, stakeCap, block.timestamp + 1, programLength);
        skip(1); // start program

        address staker1 = address(0x1);
        address staker2 = address(0x2);

        // Mint and approve stake tokens
        stakeToken.mint(staker1, 500 ether, 0);
        stakeToken.mint(staker2, 500 ether, 0);

        vm.prank(staker1);
        stakeToken.approve(address(masterBunni), type(uint256).max);

        vm.prank(staker2);
        stakeToken.approve(address(masterBunni), type(uint256).max);

        // Both stakers stake at the beginning
        RushPoolKey[] memory keys = new RushPoolKey[](1);
        keys[0] = key;

        vm.prank(staker1);
        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
        );

        vm.prank(staker2);
        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
        );

        skip(3 days);

        // Staker 1 exits after 3 days
        vm.prank(staker1);
        masterBunni.exitRushPool(keys);

        skip(2 days);

        // Staker 1 re-stakes after 2 more days (5 days total)
        vm.prank(staker1);
        masterBunni.joinRushPool(keys);

        skip(5 days); // End of program

        // Claim rewards for both stakers
        IMasterBunni.RushClaimParams[] memory params = new IMasterBunni.RushClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = keys;

        vm.prank(staker1);
        masterBunni.claimRushPool(params, staker1);

        vm.prank(staker2);
        masterBunni.claimRushPool(params, staker2);

        // Check rewards
        uint256 reward1 = incentiveToken.balanceOf(staker1);
        uint256 reward2 = incentiveToken.balanceOf(staker2);
        assertApproxEqRel(
            reward1,
            _expectedReward(key, incentiveAmount, 3 days, 500 ether)
                + _expectedReward(key, incentiveAmount, 5 days, 500 ether),
            MAX_REL_ERROR,
            "Staker 1 reward incorrect"
        );
        assertApproxEqRel(
            reward2,
            _expectedReward(key, incentiveAmount, programLength, 500 ether),
            MAX_REL_ERROR,
            "Staker 2 reward incorrect"
        );

        // Get refund
        skip(1); // skip past program end
        address refundRecipient = address(0x666);
        masterBunni.refundIncentive(params, refundRecipient);

        // Check refund amount
        assertEq(incentiveToken.balanceOf(refundRecipient), incentiveAmount - reward1 - reward2);
    }

    function test_rushPool_multipleStakers_partialUnstake() public {
        uint256 incentiveAmount = 1000 ether;
        uint256 stakeCap = 1000 ether;
        uint256 programLength = 10 days;

        (RushPoolKey memory key,, ERC20ReferrerMock stakeToken, ERC20Mock incentiveToken) =
            _createIncentive(incentiveAmount, stakeCap, block.timestamp + 1, programLength);
        skip(1); // start program

        address staker1 = address(0x1);
        address staker2 = address(0x2);

        // Mint and approve stake tokens
        stakeToken.mint(staker1, 600 ether, 0);
        stakeToken.mint(staker2, 400 ether, 0);

        vm.prank(staker1);
        stakeToken.approve(address(masterBunni), type(uint256).max);

        vm.prank(staker2);
        stakeToken.approve(address(masterBunni), type(uint256).max);

        // Both stakers stake at the beginning
        RushPoolKey[] memory keys = new RushPoolKey[](1);
        keys[0] = key;

        vm.prank(staker1);
        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
        );

        vm.prank(staker2);
        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
        );

        skip(5 days);

        // Staker 1 partially exits (300 ether) after 5 days
        vm.startPrank(staker1);
        masterBunni.exitRushPool(keys);
        IERC20Lockable[] memory stakeTokens = new IERC20Lockable[](1);
        stakeTokens[0] = stakeToken;
        masterBunni.unlock(stakeTokens);
        stakeToken.transfer(address(0xdead), 300 ether);
        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
        );
        vm.stopPrank();

        skip(5 days); // End of program

        // Claim rewards for both stakers
        IMasterBunni.RushClaimParams[] memory params = new IMasterBunni.RushClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = keys;

        vm.prank(staker1);
        masterBunni.claimRushPool(params, staker1);

        vm.prank(staker2);
        masterBunni.claimRushPool(params, staker2);

        // Check rewards
        uint256 reward1 = incentiveToken.balanceOf(staker1);
        uint256 reward2 = incentiveToken.balanceOf(staker2);
        assertApproxEqRel(
            reward1,
            _expectedReward(key, incentiveAmount, 5 days, 600 ether)
                + _expectedReward(key, incentiveAmount, 5 days, 300 ether),
            MAX_REL_ERROR,
            "Staker 1 reward incorrect"
        );
        assertApproxEqRel(
            reward2,
            _expectedReward(key, incentiveAmount, programLength, 400 ether),
            MAX_REL_ERROR,
            "Staker 2 reward incorrect"
        );

        // Get refund
        skip(1); // skip past program end
        address refundRecipient = address(0x666);
        masterBunni.refundIncentive(params, refundRecipient);

        // Check refund amount
        assertEq(incentiveToken.balanceOf(refundRecipient), incentiveAmount - reward1 - reward2);
    }

    function test_rushPool_depositIncentive_multiple() public {
        uint256[] memory incentiveAmounts = new uint256[](3);
        incentiveAmounts[0] = 100 ether;
        incentiveAmounts[1] = 200 ether;
        incentiveAmounts[2] = 300 ether;

        ERC20ReferrerMock stakeToken1 = new ERC20ReferrerMock();
        ERC20ReferrerMock stakeToken2 = new ERC20ReferrerMock();
        ERC20ReferrerMock stakeToken3 = new ERC20ReferrerMock();
        ERC20Mock incentiveToken = new ERC20Mock();

        RushPoolKey[] memory keys = new RushPoolKey[](3);
        keys[0] = RushPoolKey({
            stakeToken: stakeToken1,
            stakeCap: 1000 ether,
            startTimestamp: block.timestamp + 1 days,
            programLength: 7 days,
            lockedUntilEnd: false
        });
        keys[1] = RushPoolKey({
            stakeToken: stakeToken2,
            stakeCap: 2000 ether,
            startTimestamp: block.timestamp + 2 days,
            programLength: 14 days,
            lockedUntilEnd: false
        });
        keys[2] = RushPoolKey({
            stakeToken: stakeToken3,
            stakeCap: 3000 ether,
            startTimestamp: block.timestamp + 3 days,
            programLength: 21 days,
            lockedUntilEnd: true
        });

        IMasterBunni.RushIncentiveParams[] memory params = new IMasterBunni.RushIncentiveParams[](3);
        for (uint256 i = 0; i < 3; i++) {
            params[i] = IMasterBunni.RushIncentiveParams({key: keys[i], incentiveAmount: incentiveAmounts[i]});
        }

        uint256 totalIncentiveAmount = incentiveAmounts[0] + incentiveAmounts[1] + incentiveAmounts[2];
        incentiveToken.mint(address(this), totalIncentiveAmount);
        incentiveToken.approve(address(masterBunni), totalIncentiveAmount);

        uint256 depositedAmount = masterBunni.depositIncentive(params, address(incentiveToken), RECIPIENT);

        assertEq(depositedAmount, totalIncentiveAmount, "Total deposited amount incorrect");
        assertEq(incentiveToken.balanceOf(address(masterBunni)), totalIncentiveAmount, "MasterBunni balance incorrect");

        for (uint256 i = 0; i < 3; i++) {
            RushPoolId id = keys[i].toId();
            assertEq(
                masterBunni.rushPoolIncentiveAmounts(id, address(incentiveToken)),
                incentiveAmounts[i],
                "Incentive amount incorrect"
            );
            assertEq(
                masterBunni.rushPoolIncentiveDeposits(id, address(incentiveToken), RECIPIENT),
                incentiveAmounts[i],
                "Incentive deposit incorrect"
            );
        }
    }

    function test_rushPool_withdrawIncentive_multiple() public {
        (RushPoolKey[] memory keys, uint256[] memory incentiveAmounts, ERC20Mock incentiveToken) =
            _setupMultipleIncentives();

        IMasterBunni.RushIncentiveParams[] memory params = new IMasterBunni.RushIncentiveParams[](3);
        for (uint256 i = 0; i < 3; i++) {
            params[i] = IMasterBunni.RushIncentiveParams({key: keys[i], incentiveAmount: incentiveAmounts[i]});
        }

        uint256 totalIncentiveAmount = incentiveAmounts[0] + incentiveAmounts[1] + incentiveAmounts[2];
        uint256 withdrawnAmount = masterBunni.withdrawIncentive(params, address(incentiveToken), RECIPIENT);

        assertEq(withdrawnAmount, totalIncentiveAmount, "Total withdrawn amount incorrect");
        assertEq(incentiveToken.balanceOf(RECIPIENT), totalIncentiveAmount, "Recipient balance incorrect");
        assertEq(incentiveToken.balanceOf(address(masterBunni)), 0, "MasterBunni balance should be zero");

        for (uint256 i = 0; i < 3; i++) {
            RushPoolId id = keys[i].toId();
            assertEq(
                masterBunni.rushPoolIncentiveAmounts(id, address(incentiveToken)), 0, "Incentive amount should be zero"
            );
            assertEq(
                masterBunni.rushPoolIncentiveDeposits(id, address(incentiveToken), address(this)),
                0,
                "Incentive deposit should be zero"
            );
        }
    }

    function test_rushPool_join_multiple() public {
        (RushPoolKey[] memory keys,,) = _setupMultipleIncentives();

        address staker = address(0x1234);
        uint256 stakeAmount = 100 ether;

        for (uint256 i = 0; i < keys.length; i++) {
            ERC20ReferrerMock(address(keys[i].stakeToken)).mint(staker, stakeAmount, 0);
        }

        vm.startPrank(staker);
        for (uint256 i = 0; i < keys.length; i++) {
            ERC20ReferrerMock(address(keys[i].stakeToken)).approve(address(masterBunni), type(uint256).max);
            ERC20ReferrerMock(address(keys[i].stakeToken)).lock(
                masterBunni,
                abi.encode(
                    IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: new RushPoolKey[](0)})
                )
            );
        }

        skip(1 days); // Ensure all programs have started

        masterBunni.joinRushPool(keys);
        vm.stopPrank();

        for (uint256 i = 0; i < keys.length; i++) {
            RushPoolId id = keys[i].toId();
            (uint256 poolStakeAmount,,) = masterBunni.rushPoolStates(id);
            (uint256 userStakeAmount,,) = masterBunni.rushPoolUserStates(id, staker);

            assertEq(poolStakeAmount, stakeAmount, "Pool stake amount incorrect");
            assertEq(userStakeAmount, stakeAmount, "User stake amount incorrect");
            assertEq(
                masterBunni.userPoolCounts(staker, IERC20Lockable(address(keys[i].stakeToken))),
                1,
                "User pool count incorrect"
            );
        }
    }

    function test_rushPool_exit_multiple() public {
        (RushPoolKey[] memory keys,,) = _setupMultipleIncentives();

        address staker = address(0x1234);
        uint256 stakeAmount = 100 ether;

        for (uint256 i = 0; i < keys.length; i++) {
            ERC20ReferrerMock(address(keys[i].stakeToken)).mint(staker, stakeAmount, 0);
        }

        vm.startPrank(staker);
        for (uint256 i = 0; i < keys.length; i++) {
            ERC20ReferrerMock(address(keys[i].stakeToken)).approve(address(masterBunni), type(uint256).max);
            ERC20ReferrerMock(address(keys[i].stakeToken)).lock(
                masterBunni,
                abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
            );
        }

        skip(14 days); // Stake for 2 weeks

        masterBunni.exitRushPool(keys);
        vm.stopPrank();

        for (uint256 i = 0; i < keys.length; i++) {
            RushPoolId id = keys[i].toId();
            (uint256 poolStakeAmount,,) = masterBunni.rushPoolStates(id);
            (uint256 userStakeAmount,,) = masterBunni.rushPoolUserStates(id, staker);

            assertEq(poolStakeAmount, 0, "Pool stake amount should be zero");
            assertEq(userStakeAmount, 0, "User stake amount should be zero");
            assertEq(
                masterBunni.userPoolCounts(staker, IERC20Lockable(address(keys[i].stakeToken))),
                0,
                "User pool count should be zero"
            );
        }
    }

    function test_rushPool_claim_multiple() public {
        (RushPoolKey[] memory keys, uint256[] memory incentiveAmounts, ERC20Mock incentiveToken) =
            _setupMultipleIncentives();

        // start programs
        skip(1 days);

        address staker = address(0x1234);
        uint256 stakeAmount = 100 ether;

        for (uint256 i = 0; i < keys.length; i++) {
            ERC20ReferrerMock(address(keys[i].stakeToken)).mint(staker, stakeAmount, 0);
        }

        vm.startPrank(staker);
        for (uint256 i = 0; i < keys.length; i++) {
            ERC20ReferrerMock(address(keys[i].stakeToken)).approve(address(masterBunni), type(uint256).max);
            ERC20ReferrerMock(address(keys[i].stakeToken)).lock(
                masterBunni,
                abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
            );
        }

        skip(21 days); // Stake for 3 weeks (longest program length)

        IMasterBunni.RushClaimParams[] memory params = new IMasterBunni.RushClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = keys;

        masterBunni.claimRushPool(params, staker);
        vm.stopPrank();

        uint256 totalReward = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            RushPoolId id = keys[i].toId();
            uint256 expectedReward = _expectedReward(keys[i], incentiveAmounts[i], keys[i].programLength, stakeAmount);
            uint256 actualReward = masterBunni.rushPoolUserRewardPaid(id, staker, address(incentiveToken));

            assertApproxEqRel(actualReward, expectedReward, MAX_REL_ERROR, "Reward amount incorrect");
            totalReward += actualReward;
        }

        assertEq(incentiveToken.balanceOf(staker), totalReward, "Total claimed reward incorrect");
    }

    function test_unlock_multiple() public {
        (RushPoolKey[] memory keys,,) = _setupMultipleIncentives();

        // start programs
        skip(1 days);

        address staker = address(0x1234);
        uint256 stakeAmount = 100 ether;

        for (uint256 i = 0; i < keys.length; i++) {
            ERC20ReferrerMock(address(keys[i].stakeToken)).mint(staker, stakeAmount, 0);
        }

        vm.startPrank(staker);
        for (uint256 i = 0; i < keys.length; i++) {
            ERC20ReferrerMock(address(keys[i].stakeToken)).approve(address(masterBunni), type(uint256).max);
            ERC20ReferrerMock(address(keys[i].stakeToken)).lock(
                masterBunni,
                abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
            );
        }

        skip(21 days); // Stake for 3 weeks (longest program length)

        masterBunni.exitRushPool(keys);

        IERC20Lockable[] memory stakeTokens = new IERC20Lockable[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            stakeTokens[i] = IERC20Lockable(address(keys[i].stakeToken));
        }

        masterBunni.unlock(stakeTokens);
        vm.stopPrank();

        for (uint256 i = 0; i < keys.length; i++) {
            assertFalse(
                ERC20ReferrerMock(address(keys[i].stakeToken)).isLocked(staker), "Stake token should be unlocked"
            );
        }
    }

    function test_rushPool_refundIncentive_multiple() public {
        (RushPoolKey[] memory keys, uint256[] memory incentiveAmounts, ERC20Mock incentiveToken) =
            _setupMultipleIncentives();

        // start programs
        skip(1 days);

        address staker = address(0x1234);
        uint256 stakeAmount = 100 ether;

        for (uint256 i = 0; i < keys.length; i++) {
            ERC20ReferrerMock(address(keys[i].stakeToken)).mint(staker, stakeAmount, 0);
        }

        vm.startPrank(staker);
        for (uint256 i = 0; i < keys.length; i++) {
            ERC20ReferrerMock(address(keys[i].stakeToken)).approve(address(masterBunni), type(uint256).max);
            ERC20ReferrerMock(address(keys[i].stakeToken)).lock(
                masterBunni,
                abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
            );
        }

        skip(21 days + 1); // Stake for 3 weeks (longest program length)

        IMasterBunni.RushClaimParams[] memory claimParams = new IMasterBunni.RushClaimParams[](1);
        claimParams[0].incentiveToken = address(incentiveToken);
        claimParams[0].keys = keys;

        masterBunni.claimRushPool(claimParams, staker);
        vm.stopPrank();

        address refundRecipient = address(0x5678);
        masterBunni.refundIncentive(claimParams, refundRecipient);

        uint256 totalIncentive;
        uint256 totalClaimed;
        for (uint256 i; i < keys.length; i++) {
            totalIncentive += incentiveAmounts[i];
            totalClaimed += masterBunni.rushPoolUserRewardPaid(keys[i].toId(), staker, address(incentiveToken));
        }

        assertEq(incentiveToken.balanceOf(refundRecipient), totalIncentive - totalClaimed, "Refund amount incorrect");
    }

    function test_rushPool_multipleOperations() public {
        (RushPoolKey[] memory keys, uint256[] memory incentiveAmounts, ERC20Mock incentiveToken) =
            _setupMultipleIncentives();

        // start programs
        skip(1 days);

        address staker1 = address(0x1234);
        address staker2 = address(0x5678);
        uint256 stakeAmount = 100 ether;

        // Mint and approve stake tokens for both stakers
        for (uint256 i = 0; i < keys.length; i++) {
            ERC20ReferrerMock(address(keys[i].stakeToken)).mint(staker1, stakeAmount, 0);
            ERC20ReferrerMock(address(keys[i].stakeToken)).mint(staker2, stakeAmount, 0);
        }

        vm.startPrank(staker1);
        for (uint256 i = 0; i < keys.length; i++) {
            ERC20ReferrerMock(address(keys[i].stakeToken)).approve(address(masterBunni), type(uint256).max);
            ERC20ReferrerMock(address(keys[i].stakeToken)).lock(
                masterBunni,
                abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
            );
        }
        vm.stopPrank();

        vm.startPrank(staker2);
        for (uint256 i = 0; i < keys.length; i++) {
            ERC20ReferrerMock(address(keys[i].stakeToken)).approve(address(masterBunni), type(uint256).max);
            ERC20ReferrerMock(address(keys[i].stakeToken)).lock(
                masterBunni,
                abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
            );
        }
        vm.stopPrank();

        skip(7 days); // First program ends

        // Staker1 exits from the first pool
        RushPoolKey[] memory firstPoolKeys = new RushPoolKey[](1);
        firstPoolKeys[0] = keys[0];
        vm.prank(staker1);
        masterBunni.exitRushPool(firstPoolKeys);

        skip(7 days); // Second program ends

        // Both stakers claim rewards
        IMasterBunni.RushClaimParams[] memory claimParams = new IMasterBunni.RushClaimParams[](1);
        claimParams[0].incentiveToken = address(incentiveToken);
        claimParams[0].keys = keys;

        vm.prank(staker1);
        masterBunni.claimRushPool(claimParams, staker1);

        vm.prank(staker2);
        masterBunni.claimRushPool(claimParams, staker2);

        skip(7 days + 1); // Third program ends

        // Staker1 exits from all pools
        vm.prank(staker1);
        masterBunni.exitRushPool(keys);

        // Staker2 exits from all pools
        vm.prank(staker2);
        masterBunni.exitRushPool(keys);

        // Unlock stake tokens for both stakers
        IERC20Lockable[] memory stakeTokens = new IERC20Lockable[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            stakeTokens[i] = IERC20Lockable(address(keys[i].stakeToken));
        }

        vm.prank(staker1);
        masterBunni.unlock(stakeTokens);

        vm.prank(staker2);
        masterBunni.unlock(stakeTokens);

        // Refund remaining incentives
        address refundRecipient = address(0x9999);
        masterBunni.refundIncentive(claimParams, refundRecipient);

        // Both claim rewards
        vm.prank(staker1);
        masterBunni.claimRushPool(claimParams, staker1);

        vm.prank(staker2);
        masterBunni.claimRushPool(claimParams, staker2);

        // Verify final states
        for (uint256 i = 0; i < keys.length; i++) {
            RushPoolId id = keys[i].toId();
            (uint256 poolStakeAmount,,) = masterBunni.rushPoolStates(id);
            assertEq(poolStakeAmount, 0, "Pool stake amount should be zero");

            assertEq(
                masterBunni.userPoolCounts(staker1, IERC20Lockable(address(keys[i].stakeToken))),
                0,
                "Staker1 pool count should be zero"
            );
            assertEq(
                masterBunni.userPoolCounts(staker2, IERC20Lockable(address(keys[i].stakeToken))),
                0,
                "Staker2 pool count should be zero"
            );

            assertFalse(
                ERC20ReferrerMock(address(keys[i].stakeToken)).isLocked(staker1),
                "Staker1 stake token should be unlocked"
            );
            assertFalse(
                ERC20ReferrerMock(address(keys[i].stakeToken)).isLocked(staker2),
                "Staker2 stake token should be unlocked"
            );
        }

        uint256 totalIncentive = incentiveAmounts[0] + incentiveAmounts[1] + incentiveAmounts[2];
        uint256 totalClaimed = incentiveToken.balanceOf(staker1) + incentiveToken.balanceOf(staker2);
        assertApproxEqRel(
            incentiveToken.balanceOf(refundRecipient),
            totalIncentive - totalClaimed,
            MAX_REL_ERROR,
            "Refund amount incorrect"
        );
    }

    /// -----------------------------------------------------------------------
    /// Edge case tests
    /// -----------------------------------------------------------------------

    function test_rushPool_depositIncentive_ZeroAmount() public {
        ERC20ReferrerMock stakeToken = new ERC20ReferrerMock();
        ERC20Mock incentiveToken = new ERC20Mock();

        RushPoolKey memory key = RushPoolKey({
            stakeToken: stakeToken,
            stakeCap: 1000 ether,
            startTimestamp: block.timestamp + 1 days,
            programLength: 7 days,
            lockedUntilEnd: false
        });

        IMasterBunni.RushIncentiveParams[] memory params = new IMasterBunni.RushIncentiveParams[](1);
        params[0] = IMasterBunni.RushIncentiveParams({key: key, incentiveAmount: 0});

        uint256 depositedAmount = masterBunni.depositIncentive(params, address(incentiveToken), RECIPIENT);
        assertEq(depositedAmount, 0, "did not deposit zero amount");
    }

    function test_rushPool_depositIncentive_PastStartTimestamp(uint256 incentiveAmount) public {
        ERC20ReferrerMock stakeToken = new ERC20ReferrerMock();
        ERC20Mock incentiveToken = new ERC20Mock();
        incentiveToken.mint(address(this), incentiveAmount);
        incentiveToken.approve(address(masterBunni), type(uint256).max);

        RushPoolKey memory key = RushPoolKey({
            stakeToken: stakeToken,
            stakeCap: 1000 ether,
            startTimestamp: block.timestamp - 1 days,
            programLength: 7 days,
            lockedUntilEnd: false
        });

        IMasterBunni.RushIncentiveParams[] memory params = new IMasterBunni.RushIncentiveParams[](1);
        params[0] = IMasterBunni.RushIncentiveParams({key: key, incentiveAmount: incentiveAmount});

        uint256 depositedAmount = masterBunni.depositIncentive(params, address(incentiveToken), RECIPIENT);
        assertEq(depositedAmount, 0, "Should not deposit incentive past start timestamp");
    }

    function test_rushPool_withdrawIncentive_MoreThanDeposited() public {
        uint256 incentiveAmount = 1 ether;
        (RushPoolKey memory key,,, ERC20Mock incentiveToken) =
            _createIncentive(incentiveAmount, 1000 ether, block.timestamp + 1 days, 7 days);

        IMasterBunni.RushIncentiveParams[] memory params = new IMasterBunni.RushIncentiveParams[](1);
        params[0] = IMasterBunni.RushIncentiveParams({key: key, incentiveAmount: incentiveAmount + 1});

        vm.expectRevert();
        masterBunni.withdrawIncentive(params, address(incentiveToken), RECIPIENT);
    }

    function test_rushPool_withdrawIncentive_AfterStart() public {
        (RushPoolKey memory key,,, ERC20Mock incentiveToken) =
            _createIncentive(1000, 1000 ether, block.timestamp + 1 days, 7 days);

        skip(2 days);

        IMasterBunni.RushIncentiveParams[] memory params = new IMasterBunni.RushIncentiveParams[](1);
        params[0] = IMasterBunni.RushIncentiveParams({key: key, incentiveAmount: 1000});

        uint256 withdrawnAmount = masterBunni.withdrawIncentive(params, address(incentiveToken), RECIPIENT);
        assertEq(withdrawnAmount, 0, "Should not withdraw after start");
    }

    function test_rushPool_join_ExceedStakeCap() public {
        (RushPoolKey memory key, RushPoolId id, ERC20ReferrerMock stakeToken,) =
            _createIncentive(1000, 1000 ether, block.timestamp + 1, 7 days);
        skip(1);

        stakeToken.mint(address(this), 2000 ether, 0);

        RushPoolKey[] memory keys = new RushPoolKey[](1);
        keys[0] = key;

        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
        );

        (uint256 poolStakeAmount,,) = masterBunni.rushPoolStates(id);
        assertEq(poolStakeAmount, 1000 ether, "Should not exceed stake cap");
    }

    function test_rushPool_join_NotActive() public {
        (RushPoolKey memory key, RushPoolId id, ERC20ReferrerMock stakeToken,) =
            _createIncentive(1000, 1000 ether, block.timestamp + 1 days, 7 days);

        stakeToken.mint(address(this), 500 ether, 0);

        RushPoolKey[] memory keys = new RushPoolKey[](1);
        keys[0] = key;

        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
        );

        (uint256 poolStakeAmount,,) = masterBunni.rushPoolStates(id);
        assertEq(poolStakeAmount, 0, "Should not join before start");

        skip(100 days);

        masterBunni.joinRushPool(keys);

        (poolStakeAmount,,) = masterBunni.rushPoolStates(id);
        assertEq(poolStakeAmount, 0, "Should not join after end");
    }

    function test_rushPool_exit_NotStaked() public {
        (RushPoolKey memory key,,,) = _createIncentive(1000, 1000 ether, block.timestamp + 1, 7 days);
        skip(1);

        RushPoolKey[] memory keys = new RushPoolKey[](1);
        keys[0] = key;

        // No revert expected, but no state change should occur
        vm.record();
        masterBunni.exitRushPool(keys);
        (, bytes32[] memory writeSlots) = vm.accesses(address(masterBunni));
        assertEq(writeSlots.length, 0, "Should not update state");
    }

    function test_rushPool_exit_LockedUntilEnd() public {
        (RushPoolKey memory key, RushPoolId id, ERC20ReferrerMock stakeToken,) =
            _createIncentive(1000, 1000 ether, block.timestamp + 1 days, 7 days, true);

        stakeToken.mint(address(this), 500 ether, 0);

        RushPoolKey[] memory keys = new RushPoolKey[](1);
        keys[0] = key;

        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
        );

        // try to exit
        // No revert expected, but no state change should occur
        vm.record();
        masterBunni.exitRushPool(keys);
        (, bytes32[] memory writeSlots) = vm.accesses(address(masterBunni));
        assertEq(writeSlots.length, 0, "Should not update state");
    }

    function test_rushPool_claim_NoReward() public {
        (RushPoolKey memory key,, ERC20ReferrerMock stakeToken, ERC20Mock incentiveToken) =
            _createIncentive(1000, 1000 ether, block.timestamp + 1, 7 days);
        skip(1);

        stakeToken.mint(address(this), 500 ether, 0);

        RushPoolKey[] memory keys = new RushPoolKey[](1);
        keys[0] = key;

        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
        );

        IMasterBunni.RushClaimParams[] memory params = new IMasterBunni.RushClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = keys;

        masterBunni.claimRushPool(params, RECIPIENT);

        assertEq(incentiveToken.balanceOf(RECIPIENT), 0, "Should not claim any reward immediately after staking");
    }

    function test_unlock_StillStaked() public {
        (RushPoolKey memory key,, ERC20ReferrerMock stakeToken,) =
            _createIncentive(1000, 1000 ether, block.timestamp + 1, 7 days);
        skip(1);

        stakeToken.mint(address(this), 500 ether, 0);

        RushPoolKey[] memory keys = new RushPoolKey[](1);
        keys[0] = key;

        stakeToken.lock(
            masterBunni, abi.encode(IMasterBunni.LockCallbackData({recurKeys: new RecurPoolKey[](0), rushKeys: keys}))
        );

        IERC20Lockable[] memory stakeTokens = new IERC20Lockable[](1);
        stakeTokens[0] = stakeToken;

        masterBunni.unlock(stakeTokens);

        assertTrue(stakeToken.isLocked(address(this)), "Should not unlock while still staked");
    }

    function test_rushPool_refundIncentive_BeforeEnd() public {
        (RushPoolKey memory key,,, ERC20Mock incentiveToken) =
            _createIncentive(1000, 1000 ether, block.timestamp + 1, 7 days);
        skip(1);

        IMasterBunni.RushClaimParams[] memory params = new IMasterBunni.RushClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = new RushPoolKey[](1);
        params[0].keys[0] = key;

        masterBunni.refundIncentive(params, RECIPIENT);

        assertEq(incentiveToken.balanceOf(RECIPIENT), 0, "Should not refund before program end");
    }

    /// -----------------------------------------------------------------------
    /// Internal utilities
    /// -----------------------------------------------------------------------

    function _assumeValidFuzzParams(
        uint256 incentiveAmount,
        uint256 stakeCap,
        uint256 stakeAmount,
        uint256 programLength,
        uint256 stakeTime
    ) internal pure {
        vm.assume(
            incentiveAmount >= 1e4 && incentiveAmount <= 1e36 && stakeCap > 0 && stakeCap <= 1e36 && stakeAmount > 0
                && stakeAmount <= stakeCap && programLength > 0 && programLength < 365 days && stakeTime > 0
                && stakeTime <= programLength
        );
    }

    function _createIncentive(uint256 incentiveAmount, uint256 stakeCap, uint256 startTimestamp, uint256 programLength)
        internal
        returns (RushPoolKey memory key, RushPoolId id, ERC20ReferrerMock stakeToken, ERC20Mock incentiveToken)
    {
        return _createIncentive(incentiveAmount, stakeCap, startTimestamp, programLength, false);
    }

    function _createIncentive(
        uint256 incentiveAmount,
        uint256 stakeCap,
        uint256 startTimestamp,
        uint256 programLength,
        bool lockedUntilEnd
    )
        internal
        returns (RushPoolKey memory key, RushPoolId id, ERC20ReferrerMock stakeToken, ERC20Mock incentiveToken)
    {
        stakeToken = new ERC20ReferrerMock();

        // mint incentive token
        incentiveToken = new ERC20Mock();
        incentiveToken.mint(address(this), incentiveAmount);

        // approve incentive token to MasterBunni
        incentiveToken.approve(address(masterBunni), type(uint256).max);

        // deposit incentive
        key = RushPoolKey({
            stakeToken: stakeToken,
            stakeCap: stakeCap,
            startTimestamp: startTimestamp,
            programLength: programLength,
            lockedUntilEnd: lockedUntilEnd
        });
        id = key.toId();
        IMasterBunni.RushIncentiveParams[] memory params = new IMasterBunni.RushIncentiveParams[](1);
        params[0] = IMasterBunni.RushIncentiveParams({key: key, incentiveAmount: incentiveAmount});
        masterBunni.depositIncentive(params, address(incentiveToken), address(this));
    }

    function _expectedStakeXTime(RushPoolKey memory key, uint256 stakeTime, uint256 stakeAmount)
        internal
        pure
        returns (uint256)
    {
        return PRECISION.mulDiv(stakeAmount, key.stakeCap).mulDiv(stakeTime, key.programLength);
    }

    function _expectedReward(RushPoolKey memory key, uint256 incentiveAmount, uint256 stakeTime, uint256 stakeAmount)
        internal
        pure
        returns (uint256)
    {
        return incentiveAmount.mulDiv(_expectedStakeXTime(key, stakeTime, stakeAmount), PRECISION);
    }

    function _setupMultipleIncentives()
        internal
        returns (RushPoolKey[] memory keys, uint256[] memory incentiveAmounts, ERC20Mock incentiveToken)
    {
        keys = new RushPoolKey[](3);
        incentiveAmounts = new uint256[](3);

        keys[0] = RushPoolKey({
            stakeToken: new ERC20ReferrerMock(),
            stakeCap: 1000 ether,
            startTimestamp: block.timestamp + 1 days,
            programLength: 7 days,
            lockedUntilEnd: false
        });
        incentiveAmounts[0] = 100 ether;

        keys[1] = RushPoolKey({
            stakeToken: new ERC20ReferrerMock(),
            stakeCap: 2000 ether,
            startTimestamp: block.timestamp + 1 days,
            programLength: 14 days,
            lockedUntilEnd: false
        });
        incentiveAmounts[1] = 200 ether;

        keys[2] = RushPoolKey({
            stakeToken: new ERC20ReferrerMock(),
            stakeCap: 3000 ether,
            startTimestamp: block.timestamp + 1 days,
            programLength: 21 days,
            lockedUntilEnd: false
        });
        incentiveAmounts[2] = 300 ether;

        incentiveToken = new ERC20Mock();
        uint256 totalIncentiveAmount = incentiveAmounts[0] + incentiveAmounts[1] + incentiveAmounts[2];
        incentiveToken.mint(address(this), totalIncentiveAmount);
        incentiveToken.approve(address(masterBunni), totalIncentiveAmount);

        IMasterBunni.RushIncentiveParams[] memory params = new IMasterBunni.RushIncentiveParams[](3);
        for (uint256 i = 0; i < 3; i++) {
            params[i] = IMasterBunni.RushIncentiveParams({key: keys[i], incentiveAmount: incentiveAmounts[i]});
        }

        masterBunni.depositIncentive(params, address(incentiveToken), address(this));
    }
}
