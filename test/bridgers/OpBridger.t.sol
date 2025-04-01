// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OpBridger} from "../../src/bridgers/OpBridger.sol";
import {WETH} from "solady/tokens/WETH.sol";

contract OpBridgerTest is Test {
    OpBridger public bridger;
    WETH public weth;
    address public constant OP_BRIDGE = 0x4200000000000000000000000000000000000010;
    address public constant WETH_ADDRESS = 0x4200000000000000000000000000000000000006;
    address public recipient;
    address public owner;

    event RecipientSet(address recipient);
    event BridgeGasLimitSet(uint32 bridgeGasLimit);

    function setUp() public {
        vm.createSelectFork("base");

        recipient = makeAddr("recipient");
        owner = makeAddr("owner");
        weth = WETH(payable(WETH_ADDRESS));
        bridger = new OpBridger(recipient, owner);
    }

    function test_Constructor() public view {
        assertEq(bridger.recipient(), recipient);
        assertEq(bridger.owner(), owner);
        assertEq(bridger.bridgeGasLimit(), 2e5);
    }

    function test_SetRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit RecipientSet(newRecipient);
        bridger.setRecipient(newRecipient);
        assertEq(bridger.recipient(), newRecipient);
    }

    function test_SetRecipient_RevertUnauthorized() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        bridger.setRecipient(newRecipient);
    }

    function test_SetBridgeGasLimit() public {
        uint32 newGasLimit = 3e5;
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit BridgeGasLimitSet(newGasLimit);
        bridger.setBridgeGasLimit(newGasLimit);
        assertEq(bridger.bridgeGasLimit(), newGasLimit);
    }

    function test_SetBridgeGasLimit_RevertUnauthorized() public {
        uint32 newGasLimit = 3e5;
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert();
        bridger.setBridgeGasLimit(newGasLimit);
    }

    function test_Bridge_WithWETH() public {
        uint256 amount = 1 ether;
        deal(address(weth), address(bridger), amount);

        vm.expectCall(
            OP_BRIDGE,
            abi.encodeWithSignature("bridgeETHTo(address,uint32,bytes)", recipient, bridger.bridgeGasLimit(), bytes(""))
        );
        uint256 amountBridged = bridger.bridge();
        assertEq(amountBridged, amount);
    }

    function test_Bridge_WithETH() public {
        uint256 amount = 1 ether;
        deal(address(bridger), amount);

        vm.expectCall(
            OP_BRIDGE,
            abi.encodeWithSignature("bridgeETHTo(address,uint32,bytes)", recipient, bridger.bridgeGasLimit(), bytes(""))
        );
        uint256 amountBridged = bridger.bridge();
        assertEq(amountBridged, amount);
    }

    function test_Bridge_WithNoBalance() public {
        uint256 amountBridged = bridger.bridge();
        assertEq(amountBridged, 0);
    }

    function test_WETH_Address() public view {
        assertEq(bridger.weth(), WETH_ADDRESS);
    }

    receive() external payable {}
}
