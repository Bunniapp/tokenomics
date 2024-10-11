// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import "forge-std/Test.sol";

import {LibMulticaller} from "multicaller/LibMulticaller.sol";
import {MulticallerEtcher} from "multicaller/MulticallerEtcher.sol";
import {MulticallerWithSender} from "multicaller/MulticallerWithSender.sol";
import {MulticallerWithSigner} from "multicaller/MulticallerWithSigner.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {VyperDeployer} from "../src/lib/VyperDeployer.sol";
import {SmartWalletChecker} from "../src/SmartWalletChecker.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";

contract VotingEscrowTest is Test, VyperDeployer {
    using FixedPointMathLib for *;

    address admin;
    ERC20Mock token;
    IVotingEscrow votingEscrow;
    SmartWalletChecker smartWalletChecker;
    MulticallerWithSender multicallerWithSender;
    MulticallerWithSigner multicallerWithSigner;

    function setUp() public {
        vm.warp(1e9);
        MulticallerEtcher.multicallerWithSender();
        MulticallerEtcher.multicallerWithSigner();
        multicallerWithSender = MulticallerWithSender(payable(LibMulticaller.MULTICALLER_WITH_SENDER));
        multicallerWithSigner = MulticallerWithSigner(payable(LibMulticaller.MULTICALLER_WITH_SIGNER));

        admin = makeAddr("admin");
        token = new ERC20Mock();
        smartWalletChecker = new SmartWalletChecker(admin, new address[](0));
        votingEscrow = IVotingEscrow(
            deployContract(
                "VotingEscrow", abi.encode(token, "Vote Escrowed BUNNI", "veBUNNI", admin, smartWalletChecker)
            )
        );
    }

    function test_airdrop_noLock(uint256 amount, uint256 lockTime) public {
        vm.assume(amount > 0 && amount <= 1e27 && lockTime >= 7 days && lockTime <= 365 days);
        uint256 unlockTime = block.timestamp + lockTime;

        address airdropper = makeAddr("airdropper");
        address locker = makeAddr("locker");

        // add locker to smart wallet checker whitelist
        vm.prank(admin);
        smartWalletChecker.allowlistAddress(locker);

        // approve airdropper to airdrop tokens
        vm.prank(locker);
        votingEscrow.approve_airdrop(airdropper);

        // airdrop tokens
        token.mint(airdropper, amount);
        vm.startPrank(airdropper);
        token.approve(address(votingEscrow), amount);
        votingEscrow.airdrop(locker, amount, unlockTime);
        vm.stopPrank();

        // check result
        assertEq(uint256(uint128(votingEscrow.locked(locker).amount)), amount);
        assertEq(votingEscrow.locked(locker).end, unlockTime / (1 weeks) * (1 weeks));
        assertEq(token.balanceOf(address(votingEscrow)), amount);
    }

    function test_airdrop_hasLock(
        uint256 amount,
        uint256 lockTime,
        uint256 existingLockAmount,
        uint256 existingLockTime
    ) public {
        amount = bound(amount, 1, 1e27);
        lockTime = bound(lockTime, 7 days, 365 days);
        existingLockAmount = bound(existingLockAmount, 1, 1e27);
        existingLockTime = bound(existingLockTime, 7 days, 365 days);

        uint256 unlockTime = block.timestamp + lockTime;
        uint256 existingUnlockTime = block.timestamp + existingLockTime;

        address airdropper = makeAddr("airdropper");
        address locker = makeAddr("locker");

        // add locker to smart wallet checker whitelist
        vm.prank(admin);
        smartWalletChecker.allowlistAddress(locker);

        // create lock
        token.mint(locker, existingLockAmount);
        vm.startPrank(locker);
        token.approve(address(votingEscrow), existingLockAmount);
        votingEscrow.create_lock(existingLockAmount, existingUnlockTime);
        vm.stopPrank();

        // approve airdropper to airdrop tokens
        vm.prank(locker);
        votingEscrow.approve_airdrop(airdropper);

        // airdrop tokens
        token.mint(airdropper, amount);
        vm.startPrank(airdropper);
        token.approve(address(votingEscrow), amount);
        votingEscrow.airdrop(locker, amount, unlockTime);
        vm.stopPrank();

        // check result
        assertEq(uint256(uint128(votingEscrow.locked(locker).amount)), existingLockAmount + amount);
        assertEq(
            votingEscrow.locked(locker).end,
            FixedPointMathLib.max(existingUnlockTime, unlockTime) / (1 weeks) * (1 weeks)
        );
        assertEq(token.balanceOf(address(votingEscrow)), existingLockAmount + amount);
    }

    function test_airdrop_multicallerWithSender(uint256 amount, uint256 lockTime) public {
        vm.assume(amount > 0 && amount <= 1e27 && lockTime >= 7 days && lockTime <= 365 days);

        uint256 unlockTime = block.timestamp + lockTime;

        address locker = makeAddr("locker");

        // add locker to smart wallet checker whitelist
        vm.prank(admin);
        smartWalletChecker.allowlistAddress(locker);

        // use multicaller to approve & airdrop
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);
        targets[0] = address(votingEscrow);
        targets[1] = address(this);
        data[0] = abi.encodeCall(IVotingEscrow.approve_airdrop, (address(this)));
        data[1] = abi.encodeCall(this.airdropTo, (locker, amount, unlockTime));
        values[0] = 0;
        values[1] = 0;
        vm.prank(locker);
        multicallerWithSender.aggregateWithSender(targets, data, values);

        // check result
        assertEq(uint256(uint128(votingEscrow.locked(locker).amount)), amount);
        assertEq(votingEscrow.locked(locker).end, unlockTime / (1 weeks) * (1 weeks));
        assertEq(token.balanceOf(address(votingEscrow)), amount);
    }

    function test_airdrop_multicallerWithSigner(uint256 amount, uint256 lockTime, uint256 nonce) public {
        vm.assume(amount > 0 && amount <= 1e27 && lockTime >= 7 days && lockTime <= 365 days);

        uint256 unlockTime = block.timestamp + lockTime;

        (address locker, uint256 privateKey) = makeAddrAndKey("locker");

        // add locker to smart wallet checker whitelist
        vm.prank(admin);
        smartWalletChecker.allowlistAddress(locker);

        // use multicaller to approve & airdrop
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        uint256[] memory values = new uint256[](2);
        targets[0] = address(votingEscrow);
        targets[1] = address(this);
        data[0] = abi.encodeCall(IVotingEscrow.approve_airdrop, (address(this)));
        data[1] = abi.encodeCall(this.airdropTo, (locker, amount, unlockTime));
        values[0] = 0;
        values[1] = 0;
        _TestTemps memory t;
        {
            t.targets = targets;
            t.data = data;
            t.values = values;
            t.nonce = nonce;
            t.nonceSalt = multicallerWithSigner.nonceSaltOf(locker);
            t.signer = locker;
            t.privateKey = privateKey;
            _generateSignature(t);
        }
        multicallerWithSigner.aggregateWithSigner(targets, data, values, nonce, locker, t.signature);

        // check result
        assertEq(uint256(uint128(votingEscrow.locked(locker).amount)), amount);
        assertEq(votingEscrow.locked(locker).end, unlockTime / (1 weeks) * (1 weeks));
        assertEq(token.balanceOf(address(votingEscrow)), amount);
    }

    function test_airdrop_notApproved(uint256 amount, uint256 lockTime) public {
        vm.assume(amount > 0 && amount <= 1e27 && lockTime >= 7 days && lockTime <= 365 days);

        uint256 unlockTime = block.timestamp + lockTime;

        address locker = makeAddr("locker");
        address airdropper = makeAddr("airdropper");

        // add locker to smart wallet checker whitelist
        vm.prank(admin);
        smartWalletChecker.allowlistAddress(locker);

        // airdrop tokens
        token.mint(airdropper, amount);
        vm.startPrank(airdropper);
        token.approve(address(votingEscrow), amount);
        vm.expectRevert("Airdrop not allowed");
        votingEscrow.airdrop(locker, amount, unlockTime);
        vm.stopPrank();
    }

    function airdropTo(address to, uint256 amount, uint256 unlockTime) external {
        token.mint(address(this), amount);
        token.approve(address(votingEscrow), amount);
        votingEscrow.airdrop(to, amount, unlockTime);
    }

    struct _TestTemps {
        address[] targets;
        bytes[] data;
        uint256[] values;
        uint256 nonce;
        uint256 nonceSalt;
        bytes signature;
        address signer;
        uint256 privateKey;
    }

    function _generateSignature(_TestTemps memory t) internal view {
        unchecked {
            bytes32[] memory dataHashes = new bytes32[](t.data.length);
            for (uint256 i; i < t.data.length; ++i) {
                dataHashes[i] = keccak256(t.data[i]);
            }
            bytes32 digest = keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    _multicallerWithSignerDomainSeparator(),
                    keccak256(
                        abi.encode(
                            keccak256(
                                "AggregateWithSigner(address signer,address[] targets,bytes[] data,uint256[] values,uint256 nonce,uint256 nonceSalt)"
                            ),
                            t.signer,
                            keccak256(abi.encodePacked(t.targets)),
                            keccak256(abi.encodePacked(dataHashes)),
                            keccak256(abi.encodePacked(t.values)),
                            t.nonce,
                            t.nonceSalt
                        )
                    )
                )
            );
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(t.privateKey, digest);
            t.signature = abi.encodePacked(r, s, v);
        }
    }

    function _multicallerWithSignerDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MulticallerWithSigner"),
                keccak256("1"),
                block.chainid,
                address(multicallerWithSigner)
            )
        );
    }
}
