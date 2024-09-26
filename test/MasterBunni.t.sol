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

    IMasterBunni masterBunni;

    function setUp() public {
        vm.warp(1e9);
        masterBunni = new MasterBunni();
        MulticallerEtcher.multicallerWithSender();
        MulticallerEtcher.multicallerWithSigner();
    }

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

    function test_join_viaLock(
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

    function test_exit(
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
