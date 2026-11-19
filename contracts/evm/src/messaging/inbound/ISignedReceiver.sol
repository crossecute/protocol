// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTxEvidence, ExecutionLeaf} from "../signed/types/SignedDispatchTypes.sol";

/// @notice Permissionless submission to a receiver in signed mode.
interface ISignedReceiver {
    /// @dev An authenticated repeat of a standalone message or the current authority submission.
    event DuplicateMessage();

    /// @notice Submit a signed standalone message directly to its receiver.
    /// @dev Anyone can deliver valid evidence without a bridge; verification and replay
    ///      tracking must be shared with provider delivery. Attached value stays as a receiver
    ///      top-up.
    function submitMessage(SafeTxEvidence calldata evidence) external payable;

    /// @notice Submit a Merkle-authorized execution leaf with its signed root registration and
    ///         proof.
    /// @dev Direct submission provides a bridge-independent delivery path while retaining
    ///      signature, proof, ordering and replay checks. Attached value stays as a top-up,
    ///      including on an authenticated repeat.
    function submitLeaf(
        SafeTxEvidence calldata registrationEvidence,
        ExecutionLeaf calldata leaf,
        bytes32[] calldata proof
    ) external payable;
}

/// @notice What a transceiver asks of the receiver logic for a signed conduit. The receiver is
///         armed first with its plain initializer and no calls, then `initializeSigned` in the
///         same transaction.
interface ISignedReceiverInit {
    /// @notice Store the source authority the bootstrap carried and execute the receiver's setup.
    /// @dev The transceiver must finish this immediately after plain initialization so a
    ///      receiver created from a signed bootstrap is never exposed with plain authorization.
    /// @param sourceChainId The EIP-155 id of the home chain, which is the Safe domain's.
    /// @param owner The conduit's owner, which the root record must name.
    function initializeSigned(uint256 sourceChainId, address owner, bytes calldata body) external;
}
