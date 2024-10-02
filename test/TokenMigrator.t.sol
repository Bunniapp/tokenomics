// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import "forge-std/Test.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {TokenMigrator} from "../src/TokenMigrator.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

contract TokenMigratorTest is Test {
    using FixedPointMathLib for *;

    address internal constant RECIPIENT = address(0xB0B);

    error Unauthorized();

    ERC20Mock internal oldToken;
    ERC20Mock internal newToken;

    function setUp() public {
        oldToken = new ERC20Mock();
        newToken = new ERC20Mock();
    }

    function test_migrate(uint256 oldTokenAmount, uint256 newTokenPerOldToken) public {
        vm.assume(oldTokenAmount < 1e9 && newTokenPerOldToken < 1e36);

        TokenMigrator migrator =
            new TokenMigrator(address(oldToken), address(newToken), newTokenPerOldToken, address(this));

        oldToken.mint(address(this), oldTokenAmount);
        oldToken.approve(address(migrator), oldTokenAmount);

        uint256 expectedNewTokenAmount = oldTokenAmount.mulWad(newTokenPerOldToken);
        newToken.mint(address(migrator), expectedNewTokenAmount);

        uint256 newTokenAmount = migrator.migrate(oldTokenAmount, RECIPIENT);

        assertEq(oldToken.balanceOf(address(this)), 0, "address(this) old token balance should be zero");
        assertEq(oldToken.balanceOf(address(migrator)), oldTokenAmount, "migrator old token balance incorrect");
        assertEq(newToken.balanceOf(RECIPIENT), newTokenAmount, "New token balance incorrect");
        assertEq(newTokenAmount, expectedNewTokenAmount, "New token amount not expected");
    }

    function test_migrate_zero(uint256 newTokenPerOldToken) public {
        TokenMigrator migrator =
            new TokenMigrator(address(oldToken), address(newToken), newTokenPerOldToken, address(this));

        uint256 newTokenAmount = migrator.migrate(0, RECIPIENT);

        assertEq(oldToken.balanceOf(address(this)), 0, "address(this) old token balance should be zero");
        assertEq(oldToken.balanceOf(address(migrator)), 0, "migrator old token balance should be zero");
        assertEq(newToken.balanceOf(RECIPIENT), 0, "New token balance should be zero");
        assertEq(newTokenAmount, 0, "New token amount should be zero");
    }

    function test_withdrawNewToken(uint256 newTokenAmount, uint256 newTokenPerOldToken) public {
        TokenMigrator migrator =
            new TokenMigrator(address(oldToken), address(newToken), newTokenPerOldToken, address(this));

        newToken.mint(address(migrator), newTokenAmount);
        migrator.withdrawNewToken(newTokenAmount, RECIPIENT);

        assertEq(newToken.balanceOf(address(this)), 0, "address(this) new token balance should be zero");
        assertEq(newToken.balanceOf(RECIPIENT), newTokenAmount, "recipient new token balance incorrect");
        assertEq(newToken.balanceOf(address(migrator)), 0, "migrator new token balance should be zero");
    }

    function test_withdrawNewToken_notOwner(uint256 newTokenAmount, uint256 newTokenPerOldToken) public {
        TokenMigrator migrator =
            new TokenMigrator(address(oldToken), address(newToken), newTokenPerOldToken, address(this));

        vm.prank(address(0xB0B));
        vm.expectRevert(Unauthorized.selector);
        migrator.withdrawNewToken(newTokenAmount, RECIPIENT);
    }

    function test_setNewTokenPerOldToken(uint256 newTokenPerOldToken) public {
        TokenMigrator migrator = new TokenMigrator(address(oldToken), address(newToken), 0, address(this));

        migrator.setNewTokenPerOldToken(newTokenPerOldToken);

        assertEq(migrator.newTokenPerOldToken(), newTokenPerOldToken, "New token per old token incorrect");
    }

    function test_setNewTokenPerOldToken_notOwner(uint256 newTokenPerOldToken) public {
        TokenMigrator migrator = new TokenMigrator(address(oldToken), address(newToken), 0, address(this));

        vm.prank(address(0xB0B));
        vm.expectRevert(Unauthorized.selector);
        migrator.setNewTokenPerOldToken(newTokenPerOldToken);
    }
}
