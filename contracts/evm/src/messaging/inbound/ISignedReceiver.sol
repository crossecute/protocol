// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTxEvidence, ExecutionLeaf} from "../signed/types/SignedDispatchTypes.sol";

/// @notice Permissionless submission to a receiver in signed mode.
interface ISignedReceiver {
    /// @dev An authenticated repeat of a standalone message this receiver already executed.
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
    /// @notice Return the hash of the creation authority records encoded in a signed bootstrap.
    /// @dev The transceiver needs this commitment to derive signed conduit addresses before
    ///      deploying the receiver; record validation happens during initialization.
    function bootstrapGraph(bytes calldata body) external pure returns (bytes32);

    /// @notice Store the source authority, verify its signed bootstrap and execute the
    ///         receiver's setup.
    /// @dev The transceiver must finish this immediately after plain initialization so a
    ///      signed-address receiver is never exposed with plain authorization.
    /// @param sourceChainId The EIP-155 id of the home chain, which is the Safe domain's.
    /// @param owner The conduit's owner, which the root record must name.
    /// @param graph The graph hash the conduit's address commits to.
    function initializeSigned(uint256 sourceChainId, address owner, bytes32 graph, bytes calldata body) external;

    /// @notice Require the supplied body to be a valid repeat of this receiver's original
    ///         bootstrap.
    /// @dev Provider retries must acknowledge the same initialization without rerunning setup
    ///      or accepting a different leaf; the signed window still applies.
    function requireBootstrapRepeat(bytes calldata body) external view;
}
