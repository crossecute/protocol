// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTxEvidence, ExecutionLeaf} from "../signed/types/SignedDispatchTypes.sol";

/// @notice Permissionless submission to a receiver in signed mode.
interface ISignedReceiver {
    event SignedReceiverInitialized(address indexed sourceSafe, bytes32 graph);
    event LeafExecuted(uint256 indexed nonce, bytes32 executionId);
    event MessageExecuted(bytes32 indexed safeTxHash);

    error NotSigned();
    error NotParentTransceiver(address caller);
    error AlreadySigned();
    error UnknownWire(uint256 format);
    error ConflictingLeaf(uint256 nonce);
    error NonceNotNext(uint256 nonce, uint256 nextNonce);
    error InvalidAuthorityPins();
    error AuthorityPinsUnset();

    /// @dev An authenticated repeat of a standalone message or the current authority submission.
    event DuplicateMessage();

    /// @notice Submit a signed standalone message directly to its receiver.
    /// @dev Verification and replay tracking are shared with provider delivery. Attached value
    ///      stays as a receiver top-up.
    function submitMessage(SafeTxEvidence calldata evidence) external payable;

    /// @notice Submit a Merkle-authorized execution leaf with its signed root registration and proof.
    /// @dev Signature, proof, ordering and replay checks are those of provider delivery. Attached
    ///      value stays as a top-up, including on an authenticated repeat.
    function submitLeaf(
        SafeTxEvidence calldata registrationEvidence,
        ExecutionLeaf calldata leaf,
        bytes32[] calldata proof
    ) external payable;

    /// @notice The nonce the next new execution leaf must carry.
    function nextNonce() external view returns (uint256);
}

/// @notice What a transceiver asks of the receiver logic for a signed conduit. The receiver is
///         armed first with its base initializer and no calls, then `initializeSigned` in the
///         same transaction.
interface ISignedReceiverInit {
    /// @notice Store the source authority the bootstrap carried and execute the receiver's setup.
    /// @dev The transceiver must call this immediately after base initialization, so a receiver
    ///      created from a signed bootstrap is never exposed with unsigned authorization.
    /// @param sourceChainId The EIP-155 id of the home chain, which is the Safe domain's.
    /// @param owner The conduit's owner, which the root record must name.
    function initializeSigned(uint256 sourceChainId, address owner, bytes calldata body) external;
}
