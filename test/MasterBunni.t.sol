// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import "forge-std/Test.sol";

import {MulticallerEtcher} from "multicaller/MulticallerEtcher.sol";

import "../src/MasterBunni.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {ERC20ReferrerMock} from "./mocks/ERC20ReferrerMock.sol";

contract MasterBunniTest is Test {
    IMasterBunni masterBunni;

    function setUp() public {
        masterBunni = new MasterBunni();
        MulticallerEtcher.multicallerWithSender();
        MulticallerEtcher.multicallerWithSigner();
    }

    function test_depositIncentive_single(uint256 incentiveAmount) public {
        ERC20ReferrerMock stakeToken = new ERC20ReferrerMock();
        ERC20Mock incentiveToken = new ERC20Mock();

        // mint incentive token
        incentiveToken.mint(address(this), incentiveAmount);

        // approve incentive token to MasterBunni
        incentiveToken.approve(address(masterBunni), type(uint256).max);

        // deposit incentive
        RushPoolKey memory key = RushPoolKey({
            stakeToken: stakeToken,
            stakeCap: 1000 ether,
            startTimestamp: block.timestamp + 3 days,
            programLength: 7 days
        });
        RushPoolId id = key.toId();
        IMasterBunni.IncentiveParams[] memory params = new IMasterBunni.IncentiveParams[](1);
        params[0] = IMasterBunni.IncentiveParams({key: key, incentiveAmount: incentiveAmount});
        masterBunni.depositIncentive(params, address(incentiveToken), address(this));

        // check incentive deposit
        assertEq(incentiveToken.balanceOf(address(this)), 0);
        assertEq(incentiveToken.balanceOf(address(masterBunni)), incentiveAmount);
        assertEq(masterBunni.incentiveAmounts(id, address(incentiveToken)), incentiveAmount);
        assertEq(masterBunni.incentiveDeposits(id, address(incentiveToken), address(this)), incentiveAmount);
    }
}
