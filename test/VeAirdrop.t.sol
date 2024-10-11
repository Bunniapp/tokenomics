// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {MulticallerEtcher} from "multicaller/MulticallerEtcher.sol";
import {MulticallerWithSender} from "multicaller/MulticallerWithSender.sol";
import {MulticallerWithSigner} from "multicaller/MulticallerWithSigner.sol";

import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {VyperDeployer} from "../src/lib/VyperDeployer.sol";
import {VeAirdrop} from "../src/VeAirdrop.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
import {SmartWalletChecker} from "../src/SmartWalletChecker.sol";
import {MerkleTreeGenerator} from "./lib/MerkleTreeGenerator.sol";

contract VeAirdropTest is Test, VyperDeployer {
    uint256 internal constant LOCK_TIME = 365 days;
    uint256 internal constant MAX_SUPPLY = 1e27;

    address admin;
    ERC20Mock token;
    IVotingEscrow votingEscrow;
    SmartWalletChecker smartWalletChecker;
    MulticallerWithSender multicallerWithSender;
    MulticallerWithSigner multicallerWithSigner;

    function setUp() public {
        vm.warp(1e9);
        multicallerWithSender = MulticallerEtcher.multicallerWithSender();
        multicallerWithSigner = MulticallerEtcher.multicallerWithSigner();

        admin = makeAddr("admin");
        token = new ERC20Mock();
        smartWalletChecker = new SmartWalletChecker(admin, new address[](0));
        votingEscrow = IVotingEscrow(
            deployContract(
                "VotingEscrow", abi.encode(token, "Vote Escrowed BUNNI", "veBUNNI", admin, smartWalletChecker)
            )
        );
    }

    function test_claim(uint256 amount, uint8 treeHeightMinusOne, uint256 randomness) public {
        vm.assume(amount > 0 && amount <= MAX_SUPPLY);
        address claimer = makeAddr("claimer");

        // add locker to smart wallet checker whitelist
        vm.prank(admin);
        smartWalletChecker.allowlistAddress(claimer);

        // generate merkle proof
        (bytes32 root, bytes32[] memory proof) = MerkleTreeGenerator.generateMerkleTree(
            keccak256(abi.encodePacked(claimer, amount)), treeHeightMinusOne, keccak256(abi.encodePacked(randomness))
        );

        // create airdrop
        VeAirdrop airdrop = new VeAirdrop(root, block.timestamp + 1 days, block.timestamp + 2 days, votingEscrow, admin);

        // warp to after airdrop starts
        skip(1 days);

        // mint tokens to airdrop contract
        token.mint(address(airdrop), amount);

        // approve airdrop contract to airdrop tokens
        vm.prank(claimer);
        votingEscrow.approve_airdrop(address(airdrop));

        // claim airdrop
        vm.prank(claimer);
        airdrop.claim(amount, proof);

        // check result
        assertEq(uint256(uint128(votingEscrow.locked(claimer).amount)), amount);
        assertEq(votingEscrow.locked(claimer).end, (block.timestamp + LOCK_TIME) / (1 weeks) * (1 weeks));
        assertEq(token.balanceOf(address(votingEscrow)), amount);
    }

    function test_claim_alreadyClaimed(uint256 amount, uint8 treeHeightMinusOne, uint256 randomness) public {
        vm.assume(amount > 0 && amount <= MAX_SUPPLY);
        address claimer = makeAddr("claimer");

        // add locker to smart wallet checker whitelist
        vm.prank(admin);
        smartWalletChecker.allowlistAddress(claimer);

        // generate merkle proof
        (bytes32 root, bytes32[] memory proof) = MerkleTreeGenerator.generateMerkleTree(
            keccak256(abi.encodePacked(claimer, amount)), treeHeightMinusOne, keccak256(abi.encodePacked(randomness))
        );

        // create airdrop
        VeAirdrop airdrop = new VeAirdrop(root, block.timestamp + 1 days, block.timestamp + 2 days, votingEscrow, admin);

        // warp to after airdrop starts
        skip(1 days);

        // mint tokens to airdrop contract
        token.mint(address(airdrop), amount);

        // approve airdrop contract to airdrop tokens
        vm.prank(claimer);
        votingEscrow.approve_airdrop(address(airdrop));

        // claim airdrop
        vm.prank(claimer);
        airdrop.claim(amount, proof);

        // claim airdrop again
        vm.expectRevert(VeAirdrop.VeAirdrop__AlreadyClaimed.selector);
        vm.prank(claimer);
        airdrop.claim(amount, proof);
    }

    function test_claim_invalidMerkleProof(uint256 amount, uint8 treeHeightMinusOne, uint256 randomness) public {
        vm.assume(amount > 0 && amount <= MAX_SUPPLY);
        address claimer = makeAddr("claimer");

        // add locker to smart wallet checker whitelist
        vm.prank(admin);
        smartWalletChecker.allowlistAddress(claimer);

        // generate merkle proof
        (bytes32 root, bytes32[] memory proof) = MerkleTreeGenerator.generateMerkleTree(
            keccak256(abi.encodePacked(claimer, amount)), treeHeightMinusOne, keccak256(abi.encodePacked(randomness))
        );

        // create airdrop
        VeAirdrop airdrop = new VeAirdrop(root, block.timestamp + 1 days, block.timestamp + 2 days, votingEscrow, admin);

        // warp to after airdrop starts
        skip(1 days);

        // mint tokens to airdrop contract
        token.mint(address(airdrop), amount);

        // approve airdrop contract to airdrop tokens
        vm.prank(claimer);
        votingEscrow.approve_airdrop(address(airdrop));

        // claim airdrop requesting more than deserved
        vm.expectRevert(VeAirdrop.VeAirdrop__InvalidMerkleProof.selector);
        vm.prank(claimer);
        airdrop.claim(amount + 1, proof);
    }

    function test_claim_airdropNotActive(uint256 amount, uint8 treeHeightMinusOne, uint256 randomness) public {
        vm.assume(amount > 0 && amount <= MAX_SUPPLY);
        address claimer = makeAddr("claimer");

        // add locker to smart wallet checker whitelist
        vm.prank(admin);
        smartWalletChecker.allowlistAddress(claimer);

        // generate merkle proof
        (bytes32 root, bytes32[] memory proof) = MerkleTreeGenerator.generateMerkleTree(
            keccak256(abi.encodePacked(claimer, amount)), treeHeightMinusOne, keccak256(abi.encodePacked(randomness))
        );

        // create airdrop
        VeAirdrop airdrop = new VeAirdrop(root, block.timestamp + 1 days, block.timestamp + 2 days, votingEscrow, admin);

        // mint tokens to airdrop contract
        token.mint(address(airdrop), amount);

        // approve airdrop contract to airdrop tokens
        vm.prank(claimer);
        votingEscrow.approve_airdrop(address(airdrop));

        // try to claim airdrop before it starts
        vm.expectRevert(VeAirdrop.VeAirdrop__AirdropNotActive.selector);
        vm.prank(claimer);
        airdrop.claim(amount, proof);

        // warp to after airdrop ends
        skip(3 days);

        // try to claim airdrop after it ends
        vm.expectRevert(VeAirdrop.VeAirdrop__AirdropNotActive.selector);
        vm.prank(claimer);
        airdrop.claim(amount, proof);
    }

    function test_withdraw(uint256 amount) public {
        vm.assume(amount > 0 && amount <= MAX_SUPPLY);
        address recipient = makeAddr("recipient");

        // deploy airdrop
        VeAirdrop airdrop =
            new VeAirdrop(bytes32(0), block.timestamp + 1 days, block.timestamp + 2 days, votingEscrow, admin);

        // mint tokens to airdrop contract
        token.mint(address(airdrop), amount);

        // withdraw tokens as admin
        vm.prank(admin);
        airdrop.withdraw(address(token), amount, recipient);

        // check result
        assertEq(token.balanceOf(recipient), amount);
    }
}
