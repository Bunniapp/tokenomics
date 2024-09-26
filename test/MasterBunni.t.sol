// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import "forge-std/Test.sol";

import {MulticallerEtcher} from "multicaller/MulticallerEtcher.sol";

import "../src/MasterBunni.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {ERC20ReferrerMock} from "./mocks/ERC20ReferrerMock.sol";

contract MasterBunniTest is Test {
    using FixedPointMathLib for *;

    uint256 internal constant PRECISION = 1e30;
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

    function test_depositIncentive_single(uint256 incentiveAmount) public {
        vm.assume(incentiveAmount > 0);

        (, RushPoolId id,, ERC20Mock incentiveToken) =
            _createIncentive(incentiveAmount, 1000 ether, block.timestamp + 3 days, 7 days);

        // check incentive deposit
        assertEq(incentiveToken.balanceOf(address(this)), 0);
        assertEq(incentiveToken.balanceOf(address(masterBunni)), incentiveAmount);
        assertEq(masterBunni.incentiveAmounts(id, address(incentiveToken)), incentiveAmount);
        assertEq(masterBunni.incentiveDeposits(id, address(incentiveToken), address(this)), incentiveAmount);
    }

    function test_withdrawIncentive_single(uint256 incentiveAmount) public {
        vm.assume(incentiveAmount > 0);

        (RushPoolKey memory key, RushPoolId id,, ERC20Mock incentiveToken) =
            _createIncentive(incentiveAmount, 1000 ether, block.timestamp + 3 days, 7 days);

        // withdraw incentive
        IMasterBunni.IncentiveParams[] memory params = new IMasterBunni.IncentiveParams[](1);
        params[0] = IMasterBunni.IncentiveParams({key: key, incentiveAmount: incentiveAmount});
        masterBunni.withdrawIncentive(params, address(incentiveToken), RECIPIENT);

        // check incentive withdrawal
        assertEq(incentiveToken.balanceOf(RECIPIENT), incentiveAmount);
        assertEq(incentiveToken.balanceOf(address(masterBunni)), 0);
        assertEq(masterBunni.incentiveAmounts(id, address(incentiveToken)), 0);
        assertEq(masterBunni.incentiveDeposits(id, address(incentiveToken), address(this)), 0);
    }

    function test_refundIncentive(uint256 incentiveAmount, uint256 stakeCap, uint256 stakeAmount, uint256 programLength)
        public
    {
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
            stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: keys})));
        }

        // wait until the end of the program
        skip(programLength + 1);

        // check claimable amount
        uint256 claimableAmount = masterBunni.getClaimableReward(key, address(this), address(incentiveToken));
        assertEq(claimableAmount, _expectedReward(key, incentiveAmount, programLength, stakeAmount));

        // claim reward
        IMasterBunni.ClaimParams[] memory params = new IMasterBunni.ClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = new RushPoolKey[](1);
        params[0].keys[0] = key;
        masterBunni.claim(params, RECIPIENT);

        // check claimed amount
        assertEq(incentiveToken.balanceOf(RECIPIENT), claimableAmount);
        assertEq(masterBunni.userRewardPaid(id, address(this), address(incentiveToken)), claimableAmount);

        // get refund
        address refundRecipient = address(0x666);
        IMasterBunni.ClaimParams[] memory refundParams = new IMasterBunni.ClaimParams[](1);
        refundParams[0].incentiveToken = address(incentiveToken);
        refundParams[0].keys = new RushPoolKey[](1);
        refundParams[0].keys[0] = key;
        masterBunni.refundIncentive(refundParams, refundRecipient);

        // check refund amount
        assertEq(incentiveToken.balanceOf(refundRecipient), incentiveAmount - claimableAmount);
    }

    function test_join_single_viaLock(
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
            stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: keys})));
        }

        // check updated values
        {
            (uint256 poolStakeAmount, uint256 poolStakeXTimeStored, uint256 poolLastStakeAmountUpdateTimestamp) =
                masterBunni.poolStates(id);
            (uint256 userStakeAmount, uint256 userStakeXTimeStored, uint256 userLastStakeAmountUpdateTimestamp) =
                masterBunni.userStates(id, address(this));
            assertEq(stakeToken.balanceOf(address(this)), stakeAmount);
            assertEq(stakeToken.balanceOf(address(masterBunni)), 0);
            assertEq(masterBunni.userPoolCounts(address(this), stakeToken), 1);
            assertEq(poolStakeAmount, stakeAmount);
            assertEq(poolStakeXTimeStored, 0);
            assertEq(poolLastStakeAmountUpdateTimestamp, block.timestamp);
            assertEq(userStakeAmount, stakeAmount);
            assertEq(userStakeXTimeStored, 0);
            assertEq(userLastStakeAmountUpdateTimestamp, block.timestamp);
            assertEq(masterBunni.userRewardPaid(id, address(this), address(incentiveToken)), 0);
        }

        // wait some time
        skip(stakeTime);

        // check claimable amount
        uint256 claimableAmount = masterBunni.getClaimableReward(key, address(this), address(incentiveToken));
        assertEq(claimableAmount, _expectedReward(key, incentiveAmount, stakeTime, stakeAmount));

        // claim reward
        IMasterBunni.ClaimParams[] memory params = new IMasterBunni.ClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = new RushPoolKey[](1);
        params[0].keys[0] = key;
        masterBunni.claim(params, RECIPIENT);

        // check claimed amount
        assertEq(incentiveToken.balanceOf(RECIPIENT), claimableAmount);
        assertEq(masterBunni.userRewardPaid(id, address(this), address(incentiveToken)), claimableAmount);
    }

    function test_join_single(
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
        stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: new RushPoolKey[](0)})));

        // join pool
        {
            RushPoolKey[] memory keys = new RushPoolKey[](1);
            keys[0] = key;
            masterBunni.join(keys);
        }

        // check updated values
        {
            (uint256 poolStakeAmount, uint256 poolStakeXTimeStored, uint256 poolLastStakeAmountUpdateTimestamp) =
                masterBunni.poolStates(id);
            (uint256 userStakeAmount, uint256 userStakeXTimeStored, uint256 userLastStakeAmountUpdateTimestamp) =
                masterBunni.userStates(id, address(this));
            assertEq(stakeToken.balanceOf(address(this)), stakeAmount);
            assertEq(stakeToken.balanceOf(address(masterBunni)), 0);
            assertEq(masterBunni.userPoolCounts(address(this), stakeToken), 1);
            assertEq(poolStakeAmount, stakeAmount);
            assertEq(poolStakeXTimeStored, 0);
            assertEq(poolLastStakeAmountUpdateTimestamp, block.timestamp);
            assertEq(userStakeAmount, stakeAmount);
            assertEq(userStakeXTimeStored, 0);
            assertEq(userLastStakeAmountUpdateTimestamp, block.timestamp);
            assertEq(masterBunni.userRewardPaid(id, address(this), address(incentiveToken)), 0);
        }

        // wait some time
        skip(stakeTime);

        // check claimable amount
        uint256 claimableAmount = masterBunni.getClaimableReward(key, address(this), address(incentiveToken));
        assertEq(claimableAmount, _expectedReward(key, incentiveAmount, stakeTime, stakeAmount));

        // claim reward
        IMasterBunni.ClaimParams[] memory params = new IMasterBunni.ClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = new RushPoolKey[](1);
        params[0].keys[0] = key;
        masterBunni.claim(params, RECIPIENT);

        // check claimed amount
        assertEq(incentiveToken.balanceOf(RECIPIENT), claimableAmount);
        assertEq(masterBunni.userRewardPaid(id, address(this), address(incentiveToken)), claimableAmount);
    }

    function test_exit_single(
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
        stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: keys})));

        // wait some time
        skip(stakeTime);

        // exit the pool
        masterBunni.exit(keys);

        // check state
        {
            (uint256 poolStakeAmount, uint256 poolStakeXTimeStored, uint256 poolLastStakeAmountUpdateTimestamp) =
                masterBunni.poolStates(id);
            (uint256 userStakeAmount, uint256 userStakeXTimeStored, uint256 userLastStakeAmountUpdateTimestamp) =
                masterBunni.userStates(id, address(this));
            assertEq(stakeToken.balanceOf(address(this)), stakeAmount);
            assertEq(stakeToken.balanceOf(address(masterBunni)), 0);
            assertEq(masterBunni.userPoolCounts(address(this), stakeToken), 0);
            assertEq(poolStakeAmount, 0);
            assertEq(poolStakeXTimeStored, _expectedStakeXTime(key, stakeTime, stakeAmount));
            assertEq(poolLastStakeAmountUpdateTimestamp, block.timestamp);
            assertEq(userStakeAmount, 0);
            assertEq(userStakeXTimeStored, _expectedStakeXTime(key, stakeTime, stakeAmount));
            assertEq(userLastStakeAmountUpdateTimestamp, block.timestamp);
            assertEq(masterBunni.userRewardPaid(id, address(this), address(incentiveToken)), 0);
        }

        // wait some time
        skip(stakeTime);

        // check claimable amount
        uint256 claimableAmount = masterBunni.getClaimableReward(key, address(this), address(incentiveToken));
        assertEq(claimableAmount, _expectedReward(key, incentiveAmount, stakeTime, stakeAmount));

        // claim reward
        IMasterBunni.ClaimParams[] memory params = new IMasterBunni.ClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = new RushPoolKey[](1);
        params[0].keys[0] = key;
        masterBunni.claim(params, RECIPIENT);

        // check claimed amount
        assertEq(incentiveToken.balanceOf(RECIPIENT), claimableAmount);
        assertEq(masterBunni.userRewardPaid(id, address(this), address(incentiveToken)), claimableAmount);

        // unlock stake token
        IERC20Lockable[] memory stakeTokens = new IERC20Lockable[](1);
        stakeTokens[0] = stakeToken;
        masterBunni.unlock(stakeTokens);

        // check unlocked
        assertFalse(stakeToken.isLocked(address(this)));
    }

    function test_multipleStakers_differentStakeTimes() public {
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
        stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: keys})));
        vm.stopPrank();

        skip(2 days);

        // Staker 2 stakes after 2 days
        vm.startPrank(staker2);
        stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: keys})));
        vm.stopPrank();

        skip(3 days);

        // Staker 3 stakes after 5 days
        vm.startPrank(staker3);
        stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: keys})));
        vm.stopPrank();

        skip(5 days); // End of program

        // Claim rewards for all stakers
        IMasterBunni.ClaimParams[] memory params = new IMasterBunni.ClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = keys;

        vm.prank(staker1);
        masterBunni.claim(params, staker1);

        vm.prank(staker2);
        masterBunni.claim(params, staker2);

        vm.prank(staker3);
        masterBunni.claim(params, staker3);

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

    function test_multipleStakers_unstakeAndRestake() public {
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
        stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: keys})));

        vm.prank(staker2);
        stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: keys})));

        skip(3 days);

        // Staker 1 exits after 3 days
        vm.prank(staker1);
        masterBunni.exit(keys);

        skip(2 days);

        // Staker 1 re-stakes after 2 more days (5 days total)
        vm.prank(staker1);
        masterBunni.join(keys);

        skip(5 days); // End of program

        // Claim rewards for both stakers
        IMasterBunni.ClaimParams[] memory params = new IMasterBunni.ClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = keys;

        vm.prank(staker1);
        masterBunni.claim(params, staker1);

        vm.prank(staker2);
        masterBunni.claim(params, staker2);

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

    function test_multipleStakers_partialUnstake() public {
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
        stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: keys})));

        vm.prank(staker2);
        stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: keys})));

        skip(5 days);

        // Staker 1 partially exits (300 ether) after 5 days
        vm.startPrank(staker1);
        masterBunni.exit(keys);
        IERC20Lockable[] memory stakeTokens = new IERC20Lockable[](1);
        stakeTokens[0] = stakeToken;
        masterBunni.unlock(stakeTokens);
        stakeToken.transfer(address(0xdead), 300 ether);
        stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: keys})));
        vm.stopPrank();

        skip(5 days); // End of program

        // Claim rewards for both stakers
        IMasterBunni.ClaimParams[] memory params = new IMasterBunni.ClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = keys;

        vm.prank(staker1);
        masterBunni.claim(params, staker1);

        vm.prank(staker2);
        masterBunni.claim(params, staker2);

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

    /// -----------------------------------------------------------------------
    /// Edge case tests
    /// -----------------------------------------------------------------------

    function test_depositIncentive_ZeroAmount() public {
        ERC20ReferrerMock stakeToken = new ERC20ReferrerMock();
        ERC20Mock incentiveToken = new ERC20Mock();

        RushPoolKey memory key = RushPoolKey({
            stakeToken: stakeToken,
            stakeCap: 1000 ether,
            startTimestamp: block.timestamp + 1 days,
            programLength: 7 days
        });

        IMasterBunni.IncentiveParams[] memory params = new IMasterBunni.IncentiveParams[](1);
        params[0] = IMasterBunni.IncentiveParams({key: key, incentiveAmount: 0});

        uint256 depositedAmount = masterBunni.depositIncentive(params, address(incentiveToken), RECIPIENT);
        assertEq(depositedAmount, 0, "did not deposit zero amount");
    }

    function test_depositIncentive_PastStartTimestamp(uint256 incentiveAmount) public {
        ERC20ReferrerMock stakeToken = new ERC20ReferrerMock();
        ERC20Mock incentiveToken = new ERC20Mock();
        incentiveToken.mint(address(this), incentiveAmount);
        incentiveToken.approve(address(masterBunni), type(uint256).max);

        RushPoolKey memory key = RushPoolKey({
            stakeToken: stakeToken,
            stakeCap: 1000 ether,
            startTimestamp: block.timestamp - 1 days,
            programLength: 7 days
        });

        IMasterBunni.IncentiveParams[] memory params = new IMasterBunni.IncentiveParams[](1);
        params[0] = IMasterBunni.IncentiveParams({key: key, incentiveAmount: incentiveAmount});

        uint256 depositedAmount = masterBunni.depositIncentive(params, address(incentiveToken), RECIPIENT);
        assertEq(depositedAmount, 0, "Should not deposit incentive past start timestamp");
    }

    function test_withdrawIncentive_MoreThanDeposited() public {
        uint256 incentiveAmount = 1 ether;
        (RushPoolKey memory key,,, ERC20Mock incentiveToken) =
            _createIncentive(incentiveAmount, 1000 ether, block.timestamp + 1 days, 7 days);

        IMasterBunni.IncentiveParams[] memory params = new IMasterBunni.IncentiveParams[](1);
        params[0] = IMasterBunni.IncentiveParams({key: key, incentiveAmount: incentiveAmount + 1});

        vm.expectRevert();
        masterBunni.withdrawIncentive(params, address(incentiveToken), RECIPIENT);
    }

    function test_withdrawIncentive_AfterStart() public {
        (RushPoolKey memory key,,, ERC20Mock incentiveToken) =
            _createIncentive(1000, 1000 ether, block.timestamp + 1 days, 7 days);

        skip(2 days);

        IMasterBunni.IncentiveParams[] memory params = new IMasterBunni.IncentiveParams[](1);
        params[0] = IMasterBunni.IncentiveParams({key: key, incentiveAmount: 1000});

        uint256 withdrawnAmount = masterBunni.withdrawIncentive(params, address(incentiveToken), RECIPIENT);
        assertEq(withdrawnAmount, 0, "Should not withdraw after start");
    }

    function test_join_ExceedStakeCap() public {
        (RushPoolKey memory key, RushPoolId id, ERC20ReferrerMock stakeToken,) =
            _createIncentive(1000, 1000 ether, block.timestamp + 1, 7 days);
        skip(1);

        stakeToken.mint(address(this), 2000 ether, 0);

        RushPoolKey[] memory keys = new RushPoolKey[](1);
        keys[0] = key;

        stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: keys})));

        (uint256 poolStakeAmount,,) = masterBunni.poolStates(id);
        assertEq(poolStakeAmount, 1000 ether, "Should not exceed stake cap");
    }

    function test_join_NotActive() public {
        (RushPoolKey memory key, RushPoolId id, ERC20ReferrerMock stakeToken,) =
            _createIncentive(1000, 1000 ether, block.timestamp + 1 days, 7 days);

        stakeToken.mint(address(this), 500 ether, 0);

        RushPoolKey[] memory keys = new RushPoolKey[](1);
        keys[0] = key;

        stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: keys})));

        (uint256 poolStakeAmount,,) = masterBunni.poolStates(id);
        assertEq(poolStakeAmount, 0, "Should not join before start");

        skip(100 days);

        masterBunni.join(keys);

        (poolStakeAmount,,) = masterBunni.poolStates(id);
        assertEq(poolStakeAmount, 0, "Should not join after end");
    }

    function test_exit_NotStaked() public {
        (RushPoolKey memory key,,,) = _createIncentive(1000, 1000 ether, block.timestamp + 1, 7 days);
        skip(1);

        RushPoolKey[] memory keys = new RushPoolKey[](1);
        keys[0] = key;

        // No revert expected, but no state change should occur
        vm.record();
        masterBunni.exit(keys);
        (, bytes32[] memory writeSlots) = vm.accesses(address(masterBunni));
        assertEq(writeSlots.length, 0, "Should not update state");
    }

    function test_claim_NoReward() public {
        (RushPoolKey memory key,, ERC20ReferrerMock stakeToken, ERC20Mock incentiveToken) =
            _createIncentive(1000, 1000 ether, block.timestamp + 1, 7 days);
        skip(1);

        stakeToken.mint(address(this), 500 ether, 0);

        RushPoolKey[] memory keys = new RushPoolKey[](1);
        keys[0] = key;

        stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: keys})));

        IMasterBunni.ClaimParams[] memory params = new IMasterBunni.ClaimParams[](1);
        params[0].incentiveToken = address(incentiveToken);
        params[0].keys = keys;

        masterBunni.claim(params, RECIPIENT);

        assertEq(incentiveToken.balanceOf(RECIPIENT), 0, "Should not claim any reward immediately after staking");
    }

    function test_unlock_StillStaked() public {
        (RushPoolKey memory key,, ERC20ReferrerMock stakeToken,) =
            _createIncentive(1000, 1000 ether, block.timestamp + 1, 7 days);
        skip(1);

        stakeToken.mint(address(this), 500 ether, 0);

        RushPoolKey[] memory keys = new RushPoolKey[](1);
        keys[0] = key;

        stakeToken.lock(masterBunni, abi.encode(IMasterBunni.LockCallbackData({keys: keys})));

        IERC20Lockable[] memory stakeTokens = new IERC20Lockable[](1);
        stakeTokens[0] = stakeToken;

        masterBunni.unlock(stakeTokens);

        assertTrue(stakeToken.isLocked(address(this)), "Should not unlock while still staked");
    }

    function test_refundIncentive_BeforeEnd() public {
        (RushPoolKey memory key,,, ERC20Mock incentiveToken) =
            _createIncentive(1000, 1000 ether, block.timestamp + 1, 7 days);
        skip(1);

        IMasterBunni.ClaimParams[] memory params = new IMasterBunni.ClaimParams[](1);
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
            programLength: programLength
        });
        id = key.toId();
        IMasterBunni.IncentiveParams[] memory params = new IMasterBunni.IncentiveParams[](1);
        params[0] = IMasterBunni.IncentiveParams({key: key, incentiveAmount: incentiveAmount});
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
}
