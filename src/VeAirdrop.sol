// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {LibMulticaller} from "multicaller/LibMulticaller.sol";

import {Ownable} from "solady/auth/Ownable.sol";
import {LibBitmap} from "solady/utils/LibBitmap.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";

contract VeAirdrop is Ownable {
    using SafeTransferLib for address;
    using LibBitmap for LibBitmap.Bitmap;

    error VeAirdrop__AlreadyClaimed();
    error VeAirdrop__AirdropNotActive();
    error VeAirdrop__InvalidMerkleProof();

    event Claim(address indexed claimer, uint256 amount);

    uint256 public constant LOCK_TIME = 365 days;

    bytes32 public immutable merkleRoot;
    uint256 public immutable startTime;
    uint256 public immutable endTime;
    address public immutable underlyingToken;
    IVotingEscrow public immutable ve;

    LibBitmap.Bitmap internal hasClaimed;

    constructor(bytes32 merkleRoot_, uint256 startTime_, uint256 endTime_, IVotingEscrow ve_, address owner_) {
        merkleRoot = merkleRoot_;
        startTime = startTime_;
        endTime = endTime_;
        underlyingToken = ve_.token();
        ve = ve_;
        _initializeOwner(owner_);
        underlyingToken.safeApprove(address(ve), type(uint256).max);
    }

    /// @notice Claim vote escrowed tokens from the airdrop. Will be received by msgSender.
    /// @param amount The amount of tokens to claim.
    /// @param proof The merkle proof to prove that the sender is part of the airdrop.
    function claim(uint256 amount, bytes32[] calldata proof) external {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        // ensure airdrop is active
        if (block.timestamp < startTime || block.timestamp >= endTime) {
            revert VeAirdrop__AirdropNotActive();
        }

        // ensure msgSender has not already claimed
        address msgSender = LibMulticaller.senderOrSigner();
        uint256 hasClaimedIndex = uint160(msgSender);
        if (hasClaimed.get(hasClaimedIndex)) {
            revert VeAirdrop__AlreadyClaimed();
        }

        // validate merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msgSender, amount));
        if (!MerkleProofLib.verifyCalldata(proof, merkleRoot, leaf)) {
            revert VeAirdrop__InvalidMerkleProof();
        }

        /// -----------------------------------------------------------------------
        /// Effects
        /// -----------------------------------------------------------------------

        // record that msgSender has claimed
        hasClaimed.set(hasClaimedIndex);

        /// -----------------------------------------------------------------------
        /// Interactions
        /// -----------------------------------------------------------------------

        ve.airdrop(msgSender, amount, block.timestamp + LOCK_TIME);

        emit Claim(msgSender, amount);
    }

    /// @notice Lets the owner withdraw tokens.
    /// @param token The token to withdraw.
    /// @param amount The amount of tokens to withdraw.
    /// @param recipient The address to receive the tokens.
    function withdraw(address token, uint256 amount, address recipient) external onlyOwner {
        token.safeTransfer(recipient, amount);
    }
}
