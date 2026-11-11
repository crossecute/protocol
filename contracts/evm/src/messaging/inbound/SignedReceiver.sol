// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Call} from "src/messaging/Call.sol";
import {SafeAuthorityState, SafeAuthority} from "src/messaging/signed/SafeAuthority.sol";
import {SafeAuthorityGraph} from "src/messaging/signed/SafeAuthorityGraph.sol";
import {DispatchLeaves} from "src/messaging/signed/DispatchLeaves.sol";
import {SignedDispatchCalls} from "src/messaging/signed/SignedDispatchCalls.sol";
import {SafeAuthorityRecord} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {
    ExecutionLeaf,
    BootstrapLeaf,
    SafeTxEvidence,
    SignedBootstrap,
    WIRE_STANDALONE,
    WIRE_MERKLE
} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {ISignedReceiver, ISignedReceiverInit} from "src/messaging/inbound/ISignedReceiver.sol";

/// @title SignedReceiver
/// @notice A receiver that can be created in signed mode (#108): it stores its source Safe's
///         creation authority and executes only what that authority signed, delivered by its
///         provider or submitted by anyone.
///
/// @dev Plain until `initializeSigned`, which the transceiver calls right after arming the
///      receiver with its plain initializer and no calls, in the same transaction. A receiver
///      at a signed address is never left plain: its address commits to the graph, so only the
///      signed bootstrap path creates it.
///
/// @dev In signed mode the source transmitter's address grants nothing: `execute`, `commit`,
///      `cancel` and `revokeGateway` answer only to this receiver's own calls, made by verified
///      signed execution or by `finalize` of a commitment such execution recorded.
///
/// @dev State is ERC-7201 namespaced so it does not extend the base's sequential layout (R8.2).
abstract contract SignedReceiver is ReceiverBase, ISignedReceiver, ISignedReceiverInit {
    using SafeAuthority for SafeAuthorityState;

    /// @custom:storage-location erc7201:crossecute.storage.SignedReceiver
    struct SignedReceiverStorage {
        SafeAuthorityState authority;
        // Nonzero exactly in signed mode.
        bytes32 graph;
        bytes32 bootstrapLeaf;
        uint256 nextNonce;
        mapping(uint256 nonce => bytes32 executionId) executions;
        mapping(bytes32 safeTxHash => bool) messages;
    }

    // keccak256(abi.encode(uint256(keccak256("crossecute.storage.SignedReceiver")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SIGNED_RECEIVER_STORAGE =
        0xee70333bd3c831863985f85848a518f67d0a54c38e49f2065c9698952a1a6e00;

    event SignedReceiverInitialized(address indexed sourceSafe, bytes32 graph, bytes32 bootstrapLeaf);
    event LeafExecuted(uint256 indexed nonce, bytes32 executionId);
    event MessageExecuted(bytes32 indexed safeTxHash);

    error NotSigned();
    error NotParentTransceiver(address caller);
    error AlreadySigned();
    error AuthorityGraphMismatch(bytes32 expected, bytes32 carried);
    error RootIsNotOwner(address owner, address root);
    error UnknownWire(uint256 format);
    error ConflictingLeaf(uint256 nonce);
    error NonceNotNext(uint256 nonce, uint256 nextNonce);
    error NotTheBootstrap(bytes32 leafHash);

    /// @notice Return this receiver's namespaced signed-mode storage.
    /// @dev A fixed namespace keeps the added authority and replay state separate from the base
    ///      contract's sequential layout.
    function _signedStorage() private pure returns (SignedReceiverStorage storage $) {
        assembly ("memory-safe") {
            $.slot := SIGNED_RECEIVER_STORAGE
        }
    }

    /// @notice Return whether this receiver has a nonzero creation-graph commitment.
    /// @dev Message handling and access checks use this flag to retain plain behavior until
    ///      signed initialization has completed.
    function _isSigned() internal view returns (bool) {
        return _signedStorage().graph != bytes32(0);
    }

    /* ================================ initializing ============================== */

    /// @notice Hash the creation records carried in the encoded signed bootstrap.
    /// @dev The transceiver needs this value to derive the receiver address before
    ///      initialization validates those records.
    /// @inheritdoc ISignedReceiverInit
    function bootstrapGraph(bytes calldata body) external pure returns (bytes32) {
        return SafeAuthorityGraph.hash(abi.decode(body, (SignedBootstrap)).records);
    }

    /// @notice Validate and store the source authority, verify the bootstrap and run its setup
    ///         calls.
    /// @dev Binding the source owner and graph to the derived address prevents authority
    ///      substitution. Any failed check or setup call reverts initialization atomically.
    function initializeSigned(uint256 sourceChainId, address owner, bytes32 graph, bytes calldata body)
        external
        nonReentrant
    {
        if (msg.sender != parentTransceiver) revert NotParentTransceiver(msg.sender);
        SignedReceiverStorage storage $ = _signedStorage();
        if ($.graph != bytes32(0)) revert AlreadySigned();

        SignedBootstrap memory bootstrap = abi.decode(body, (SignedBootstrap));
        SafeAuthorityRecord[] memory records = bootstrap.records;
        bytes32 carried = SafeAuthorityGraph.hash(records);
        if (carried != graph) revert AuthorityGraphMismatch(graph, carried);
        $.authority.store(records, sourceChainId);
        if (records[0].safe != owner) revert RootIsNotOwner(owner, records[0].safe);
        $.graph = graph;

        (bytes32 leafHash, BootstrapLeaf memory leaf) = _verifyBootstrap(bootstrap.evidence);
        $.bootstrapLeaf = leafHash;
        emit SignedReceiverInitialized(owner, graph, leafHash);

        Call[] memory calls = Payload.decodeCallsFromMemory(leaf.setupCalls);
        if (calls.length != 0) _execute(calls);
    }

    /// @notice Verify that a bootstrap body authorizes the same leaf that initialized this
    ///         receiver.
    /// @dev This makes transport retries harmless without allowing setup to run twice or a
    ///      different bootstrap to replace the original one.
    /// @inheritdoc ISignedReceiverInit
    function requireBootstrapRepeat(bytes calldata body) external view {
        (bytes32 leafHash,) = _verifyBootstrap(abi.decode(body, (SignedBootstrap)).evidence);
        bytes32 stored = _signedStorage().bootstrapLeaf;
        if (leafHash != stored) revert NotTheBootstrap(leafHash);
    }

    /// @notice Check the signed bootstrap's source call, proof, destination, signatures and
    ///         time window.
    /// @dev Receiver setup must be explicitly authorized for this address; even a repeat must
    ///      remain inside the original signed window.
    function _verifyBootstrap(SafeTxEvidence memory evidence)
        private
        view
        returns (bytes32 leafHash, BootstrapLeaf memory leaf)
    {
        SignedDispatchCalls.requireSourceCall(evidence.signedSafeTx.safeTx, sourceTransmitter);
        bytes32 root;
        bytes32[] memory proof;
        (root, leaf, proof,) = SignedDispatchCalls.bootstrapArgs(evidence.signedSafeTx.safeTx.data);
        SignedDispatchCalls.requireDestination(leaf.destination, address(this));
        leafHash = DispatchLeaves.hash(leaf);
        DispatchLeaves.requireProof(proof, root, leafHash);
        _verify(evidence);
        SignedDispatchCalls.requireOpen(leaf.validAfter, leaf.deadline);
    }

    /* ================================== dispatch ================================ */

    /// @notice Accept a standalone signed message directly from any caller.
    /// @dev This provides delivery without the provider while using the same verifier, replay
    ///      state and reentrancy lock as signed provider messages.
    /// @inheritdoc ISignedReceiver
    function submitMessage(SafeTxEvidence calldata evidence) external payable nonReentrant {
        if (!_isSigned()) revert NotSigned();
        _runMessage(evidence);
    }

    /// @notice Accept a signed root registration and execution leaf directly from any caller.
    /// @dev Bridge-independent submission must enforce the same proof, nonce and replay rules
    ///      as provider delivery. Attached value tops up the receiver.
    /// @inheritdoc ISignedReceiver
    function submitLeaf(
        SafeTxEvidence calldata registrationEvidence,
        ExecutionLeaf calldata leaf,
        bytes32[] calldata proof
    ) external payable nonReentrant {
        if (!_isSigned()) revert NotSigned();
        _runLeaf(registrationEvidence, leaf, proof);
    }

    /// @notice Dispatch an authenticated provider payload through plain or signed handling
    ///         according to this receiver's mode.
    /// @dev The base has already checked gateway, origin and sender; signed mode additionally
    ///      requires a recognized signed envelope and independently verified authorization.
    function _onMessage(bytes calldata payload) internal override {
        if (!_isSigned()) return super._onMessage(payload);
        _onSignedMessage(payload);
    }

    /// @notice Decode the signed wire-format tag and dispatch its standalone message or Merkle
    ///         leaf under the receiver lock.
    /// @dev Explicit tags prevent interpreting one payload format as another, and the lock
    ///      prevents nested delivery from bypassing execution ordering.
    function _onSignedMessage(bytes calldata payload) private nonReentrant {
        uint256 format = payload.length < 32 ? 0 : abi.decode(payload[:32], (uint256));
        if (format == WIRE_STANDALONE) {
            (, SafeTxEvidence memory evidence) = abi.decode(payload, (uint256, SafeTxEvidence));
            _runMessage(evidence);
        } else if (format == WIRE_MERKLE) {
            (, SafeTxEvidence memory evidence, ExecutionLeaf memory leaf, bytes32[] memory proof) =
                abi.decode(payload, (uint256, SafeTxEvidence, ExecutionLeaf, bytes32[]));
            _runLeaf(evidence, leaf, proof);
        } else {
            revert UnknownWire(format);
        }
    }

    /// @notice Verify and execute a standalone message once, keyed by its source Safe
    ///         transaction hash.
    /// @dev Direct and provider delivery share the digest record, so resubmitting valid
    ///      evidence cannot repeat its calls. A failed execution reverts the record too.
    function _runMessage(SafeTxEvidence memory evidence) private {
        SignedDispatchCalls.requireSourceCall(evidence.signedSafeTx.safeTx, sourceTransmitter);
        (bytes memory recipient, bytes memory payload,) =
            SignedDispatchCalls.sendMessageArgs(evidence.signedSafeTx.safeTx.data);
        SignedDispatchCalls.requireDestination(recipient, address(this));
        bytes32 safeTxHash = _verify(evidence);

        SignedReceiverStorage storage $ = _signedStorage();
        if ($.messages[safeTxHash]) {
            emit DuplicateMessage();
            return;
        }
        $.messages[safeTxHash] = true;
        emit MessageExecuted(safeTxHash);
        Call[] memory calls = Payload.decodeCallsFromMemory(payload);
        emit Delivered(calls.length);
        _execute(calls);
    }

    /// @notice Verify a root-authorized leaf and execute it at the next local nonce.
    /// @dev Proof and signature checks establish authority; nonce tracking preserves order and
    ///      rejects conflicts. A matching execution ID returns silently even after expiry or a
    ///      change of delivery attributes; failed calls roll back the nonce and record.
    function _runLeaf(SafeTxEvidence memory registrationEvidence, ExecutionLeaf memory leaf, bytes32[] memory proof)
        private
    {
        SignedDispatchCalls.requireSourceCall(registrationEvidence.signedSafeTx.safeTx, sourceTransmitter);
        bytes32 root = SignedDispatchCalls.registeredRoot(registrationEvidence.signedSafeTx.safeTx);
        SignedDispatchCalls.requireDestination(leaf.destination, address(this));
        DispatchLeaves.requireProof(proof, root, DispatchLeaves.hash(leaf));
        _verify(registrationEvidence);

        SignedReceiverStorage storage $ = _signedStorage();
        bytes32 id = DispatchLeaves.executionId(leaf);
        bytes32 stored = $.executions[leaf.nonce];
        // An executed batch is acknowledged silently, at any time and under any root.
        if (stored == id) return;
        if (stored != bytes32(0)) revert ConflictingLeaf(leaf.nonce);
        if (leaf.nonce != $.nextNonce) revert NonceNotNext(leaf.nonce, $.nextNonce);
        SignedDispatchCalls.requireOpen(leaf.validAfter, leaf.deadline);

        $.executions[leaf.nonce] = id;
        $.nextNonce = leaf.nonce + 1;
        emit LeafExecuted(leaf.nonce, id);
        Call[] memory calls = Payload.decodeCallsFromMemory(leaf.calls);
        emit Delivered(calls.length);
        _execute(calls);
    }

    /// @notice Hash the exact source Safe transaction and verify its root and nested signatures
    ///         against stored authority.
    /// @dev The source Safe address and chain domain bind the evidence to its original signer
    ///      context; the delivery caller does not grant authorization.
    function _verify(SafeTxEvidence memory evidence) private view returns (bytes32 safeTxHash) {
        SafeAuthorityState storage authority = _signedStorage().authority;
        safeTxHash = SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, authority.root, authority.sourceChainId);
        authority.verify(safeTxHash, evidence.signedSafeTx.signatures, evidence.nestedApprovals);
    }

    /* =================================== access ================================= */

    /// @notice In signed mode, authorize protected calls only when this receiver calls itself.
    /// @dev Verified execution and later commitment finalization can make those self-calls; the
    ///      source transmitter address alone grants no authority. Plain mode retains the base
    ///      rules.
    function isAuthorizedCaller(address conduit) public view override returns (bool) {
        if (_isSigned()) return conduit == address(this);
        return super.isAuthorizedCaller(conduit);
    }

    /* =================================== views ================================== */

    /// @notice Return the stored creation-graph hash, or zero for a plain receiver.
    /// @dev Callers can identify signed mode and compare its fixed authority commitment with
    ///      the address derivation.
    function authorityGraph() external view returns (bytes32) {
        return _signedStorage().graph;
    }

    /// @notice Return the stored Safe authority records in canonical order.
    /// @dev This exposes the receiver's actual verification snapshot so callers can inspect it
    ///      and reproduce the creation-graph hash.
    function authorityRecords() external view returns (SafeAuthorityRecord[] memory) {
        return _signedStorage().authority.readRecords();
    }

    /// @notice Return the nonce required by the next new execution leaf.
    /// @dev Relayers need this receiver-local ordering value to know which authorized batch can
    ///      execute next.
    function nextNonce() external view returns (uint256) {
        return _signedStorage().nextNonce;
    }

    /// @notice Return the execution ID recorded at a nonce, or zero if unused.
    /// @dev This lets callers distinguish an unexecuted position from an already executed batch
    ///      before retrying a delivery.
    function executionAt(uint256 nonce) external view returns (bytes32) {
        return _signedStorage().executions[nonce];
    }

    /// @notice Report whether a standalone Safe transaction hash has already executed.
    /// @dev Relayers can inspect the shared replay record rather than assuming a failed or
    ///      duplicated transport message needs execution.
    function isMessageExecuted(bytes32 safeTxHash) external view returns (bool) {
        return _signedStorage().messages[safeTxHash];
    }

    /// @notice Return the leaf hash that authorized this receiver's initial setup.
    /// @dev The hash identifies the only bootstrap leaf the receiver will acknowledge as a
    ///      repeat.
    function bootstrapLeaf() external view returns (bytes32) {
        return _signedStorage().bootstrapLeaf;
    }
}
