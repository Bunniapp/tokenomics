// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {WETH} from "solady/tokens/WETH.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {IBridger} from "../interfaces/IBridger.sol";

interface StandardBridge {
    function bridgeETHTo(address _to, uint32 _minGasLimit, bytes calldata _extraData) external payable;
}

/// @title OpBridger
/// @notice Bridges WETH from OP-stack L2 to Ethereum via the standard bridge
/// @author zefram.eth
contract OpBridger is IBridger, Ownable {
    StandardBridge public constant opBridge = StandardBridge(0x4200000000000000000000000000000000000010);

    WETH internal constant _weth = WETH(payable(0x4200000000000000000000000000000000000006));

    /// @inheritdoc IBridger
    address public override recipient;

    uint32 public bridgeGasLimit;

    event RecipientSet(address recipient);
    event BridgeGasLimitSet(uint32 bridgeGasLimit);

    constructor(address recipient_, address owner_) {
        recipient = recipient_;
        _initializeOwner(owner_);
        bridgeGasLimit = 2e5;

        emit RecipientSet(recipient_);
        emit BridgeGasLimitSet(2e5);
    }

    /// @inheritdoc IBridger
    function bridge() external returns (uint256 amountBridged) {
        // unwrap WETH to ETH
        uint256 wethBalance = _weth.balanceOf(address(this));
        if (wethBalance != 0) {
            _weth.withdraw(wethBalance);
        }

        // bridge ETH to Ethereum
        amountBridged = address(this).balance;
        if (amountBridged != 0) {
            opBridge.bridgeETHTo{value: amountBridged}(recipient, bridgeGasLimit, bytes(""));
        }
    }

    /// @inheritdoc IBridger
    function weth() external pure returns (address) {
        return address(_weth);
    }

    function setRecipient(address recipient_) external onlyOwner {
        recipient = recipient_;
        emit RecipientSet(recipient_);
    }

    function setBridgeGasLimit(uint32 bridgeGasLimit_) external onlyOwner {
        bridgeGasLimit = bridgeGasLimit_;
        emit BridgeGasLimitSet(bridgeGasLimit_);
    }

    receive() external payable {}
}
