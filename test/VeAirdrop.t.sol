// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {LibMulticaller} from "multicaller/LibMulticaller.sol";
import {MulticallerEtcher} from "multicaller/MulticallerEtcher.sol";

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

    function setUp() public {
        vm.warp(1e9);
        admin = makeAddr("admin");
        token = new ERC20Mock();
        smartWalletChecker = new SmartWalletChecker(admin, new address[](0));
        votingEscrow = IVotingEscrow(
            deployContract(
                "VotingEscrow", abi.encode(token, "Vote Escrowed BUNNI", "veBUNNI", admin, smartWalletChecker)
            )
        );
        MulticallerEtcher.multicallerWithSender();
        MulticallerEtcher.multicallerWithSigner();
    }

    function test_claim(uint256 amount, uint8 treeHeightMinusOne, uint256 randomness) public {
        address claimer = makeAddr("claimer");
        (VeAirdrop airdrop, bytes32[] memory proof) = setupAirdrop(amount, treeHeightMinusOne, randomness, claimer);

        // Claim airdrop
        vm.prank(claimer);
        airdrop.claim(amount, proof);

        // Check result
        assertEq(uint256(uint128(votingEscrow.locked(claimer).amount)), amount);
        assertEq(votingEscrow.locked(claimer).end, (block.timestamp + LOCK_TIME) / (1 weeks) * (1 weeks));
        assertEq(token.balanceOf(address(votingEscrow)), amount);
    }

    function test_claim_alreadyClaimed(uint256 amount, uint8 treeHeightMinusOne, uint256 randomness) public {
        address claimer = makeAddr("claimer");
        (VeAirdrop airdrop, bytes32[] memory proof) = setupAirdrop(amount, treeHeightMinusOne, randomness, claimer);

        // Claim airdrop
        vm.prank(claimer);
        airdrop.claim(amount, proof);

        // Claim airdrop again
        vm.expectRevert(VeAirdrop.VeAirdrop__AlreadyClaimed.selector);
        vm.prank(claimer);
        airdrop.claim(amount, proof);
    }

    function test_claim_invalidMerkleProof(uint256 amount, uint8 treeHeightMinusOne, uint256 randomness) public {
        address claimer = makeAddr("claimer");
        (VeAirdrop airdrop, bytes32[] memory proof) = setupAirdrop(amount, treeHeightMinusOne, randomness, claimer);

        // Claim airdrop requesting more than deserved
        vm.expectRevert(VeAirdrop.VeAirdrop__InvalidMerkleProof.selector);
        vm.prank(claimer);
        airdrop.claim(amount + 1, proof);
    }

    function test_claim_airdropNotActive(uint256 amount, uint8 treeHeightMinusOne, uint256 randomness) public {
        address claimer = makeAddr("claimer");
        (VeAirdrop airdrop, bytes32[] memory proof) = setupAirdrop(amount, treeHeightMinusOne, randomness, claimer);

        // Try to claim airdrop before it starts
        vm.warp(block.timestamp - 2 days);
        vm.expectRevert(VeAirdrop.VeAirdrop__AirdropNotActive.selector);
        vm.prank(claimer);
        airdrop.claim(amount, proof);

        // Try to claim airdrop after it ends
        vm.warp(block.timestamp + 4 days);
        vm.expectRevert(VeAirdrop.VeAirdrop__AirdropNotActive.selector);
        vm.prank(claimer);
        airdrop.claim(amount, proof);
    }

    function test_withdraw(uint256 amount) public {
        vm.assume(amount > 0 && amount <= MAX_SUPPLY);
        address recipient = makeAddr("recipient");

        // Deploy airdrop
        VeAirdrop airdrop =
            new VeAirdrop(bytes32(0), block.timestamp + 1 days, block.timestamp + 2 days, votingEscrow, admin);

        // Mint tokens to airdrop contract
        token.mint(address(airdrop), amount);

        // Withdraw tokens as admin
        vm.prank(admin);
        airdrop.withdraw(address(token), amount, recipient);

        // Check result
        assertEq(token.balanceOf(recipient), amount);
    }

    // Helper function to set up the airdrop for testing
    function setupAirdrop(uint256 amount, uint8 treeHeightMinusOne, uint256 randomness, address claimer)
        internal
        returns (VeAirdrop airdrop, bytes32[] memory proof)
    {
        vm.assume(amount > 0 && amount <= MAX_SUPPLY);

        // Add locker to smart wallet checker whitelist
        vm.prank(admin);
        smartWalletChecker.allowlistAddress(claimer);

        // Generate merkle proof
        bytes32 root;
        (root, proof) = MerkleTreeGenerator.generateMerkleTree(
            keccak256(abi.encodePacked(claimer, amount)), treeHeightMinusOne, keccak256(abi.encodePacked(randomness))
        );

        // Create airdrop
        airdrop = new VeAirdrop(root, block.timestamp + 1 days, block.timestamp + 2 days, votingEscrow, admin);

        // Warp to after airdrop starts
        skip(1 days);

        // Mint tokens to airdrop contract
        token.mint(address(airdrop), amount);

        // Approve airdrop contract to airdrop tokens
        vm.prank(claimer);
        votingEscrow.approve_airdrop(address(airdrop));
    }
}
