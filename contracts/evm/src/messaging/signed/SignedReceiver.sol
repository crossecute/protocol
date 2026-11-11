// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Call} from "src/messaging/Call.sol";
import {Authority, SafeAuthority} from "src/messaging/signed/SafeAuthority.sol";
import {AuthorityGraph} from "src/messaging/signed/AuthorityGraph.sol";
import {DispatchLeaves} from "src/messaging/signed/DispatchLeaves.sol";
import {SignedCalls} from "src/messaging/signed/SignedCalls.sol";
import {
    SafeRecord,
    ExecutionLeaf,
    BootstrapLeaf,
    SignedDelivery,
    SignedBootstrap,
    ISignedReceiver,
    ISignedReceiverInit,
    WIRE_STANDALONE,
    WIRE_MERKLE
} from "src/messaging/signed/ISignedDispatch.sol";

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
    using SafeAuthority for Authority;

    /// @custom:storage-location erc7201:crossecute.storage.SignedReceiver
    struct SignedReceiverStorage {
        Authority authority;
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
    error GraphMismatch(bytes32 expected, bytes32 carried);
    error RootIsNotOwner(address owner, address root);
    error UnknownWire(uint256 format);
    error ConflictingLeaf(uint256 nonce);
    error NonceNotNext(uint256 nonce, uint256 nextNonce);
    error NotTheBootstrap(bytes32 leafHash);

    function _signedStorage() private pure returns (SignedReceiverStorage storage $) {
        assembly ("memory-safe") {
            $.slot := SIGNED_RECEIVER_STORAGE
        }
    }

    function _isSigned() internal view returns (bool) {
        return _signedStorage().graph != bytes32(0);
    }

    /* ================================ initializing ============================== */

    /// @inheritdoc ISignedReceiverInit
    function bootstrapGraph(bytes calldata body) external pure returns (bytes32) {
        return AuthorityGraph.hash(abi.decode(body, (SignedBootstrap)).records);
    }

    /// @notice Store the creation authority, verify the signed bootstrap against it, and run its
    ///         setup calls. Reverts, undoing the receiver's creation, if any check fails.
    /// @dev The transceiver derived this address from `owner`, the envelope's salt and `graph`,
    ///      so binding the records to both here binds them to the address.
    function initializeSigned(uint256 sourceChainId, address owner, bytes32 graph, bytes calldata body)
        external
        nonReentrant
    {
        if (msg.sender != parentTransceiver) revert NotParentTransceiver(msg.sender);
        SignedReceiverStorage storage $ = _signedStorage();
        if ($.graph != bytes32(0)) revert AlreadySigned();

        SignedBootstrap memory b = abi.decode(body, (SignedBootstrap));
        SafeRecord[] memory records = b.records;
        bytes32 carried = AuthorityGraph.hash(records);
        if (carried != graph) revert GraphMismatch(graph, carried);
        $.authority.store(records, sourceChainId);
        if (records[0].safe != owner) revert RootIsNotOwner(owner, records[0].safe);
        $.graph = graph;

        (bytes32 leafHash, BootstrapLeaf memory leaf) = _verifyBootstrap(b.delivery);
        $.bootstrapLeaf = leafHash;
        emit SignedReceiverInitialized(owner, graph, leafHash);

        Call[] memory calls = Payload.decodeCallsFromMemory(leaf.setupCalls);
        if (calls.length != 0) _execute(calls);
    }

    /// @inheritdoc ISignedReceiverInit
    function requireBootstrapRepeat(bytes calldata body) external view {
        (bytes32 leafHash,) = _verifyBootstrap(abi.decode(body, (SignedBootstrap)).delivery);
        bytes32 stored = _signedStorage().bootstrapLeaf;
        if (leafHash != stored) revert NotTheBootstrap(leafHash);
    }

    /// @dev Target, selector, proof, destination, window and signatures. A repeat is held to the
    ///      same window as the first delivery.
    function _verifyBootstrap(SignedDelivery memory d)
        private
        view
        returns (bytes32 leafHash, BootstrapLeaf memory leaf)
    {
        SignedCalls.requireSourceCall(d.safeTx, sourceTransmitter);
        bytes32 root;
        bytes32[] memory proof;
        (root, leaf, proof,) = SignedCalls.bootstrapArgs(d.safeTx.data);
        SignedCalls.requireDestination(leaf.destination, address(this));
        leafHash = DispatchLeaves.hash(leaf);
        DispatchLeaves.requireProof(proof, root, leafHash);
        _verify(d);
        SignedCalls.requireOpen(leaf.validAfter, leaf.deadline);
    }

    /* ================================== dispatch ================================ */

    /// @inheritdoc ISignedReceiver
    function submitMessage(SignedDelivery calldata delivery) external payable nonReentrant {
        if (!_isSigned()) revert NotSigned();
        _runMessage(delivery);
    }

    /// @inheritdoc ISignedReceiver
    function submitLeaf(SignedDelivery calldata registration, ExecutionLeaf calldata leaf, bytes32[] calldata proof)
        external
        payable
        nonReentrant
    {
        if (!_isSigned()) revert NotSigned();
        _runLeaf(registration, leaf, proof);
    }

    /// @dev Provider delivery, after the base's gateway, origin and sender checks. In signed mode
    ///      every payload is a signed wire message.
    function _onMessage(bytes calldata payload) internal override {
        if (!_isSigned()) return super._onMessage(payload);
        _onSignedMessage(payload);
    }

    function _onSignedMessage(bytes calldata payload) private nonReentrant {
        uint256 format = payload.length < 32 ? 0 : abi.decode(payload[:32], (uint256));
        if (format == WIRE_STANDALONE) {
            (, SignedDelivery memory d) = abi.decode(payload, (uint256, SignedDelivery));
            _runMessage(d);
        } else if (format == WIRE_MERKLE) {
            (, SignedDelivery memory d, ExecutionLeaf memory leaf, bytes32[] memory proof) =
                abi.decode(payload, (uint256, SignedDelivery, ExecutionLeaf, bytes32[]));
            _runLeaf(d, leaf, proof);
        } else {
            revert UnknownWire(format);
        }
    }

    /// @dev R3 to R16 for a signed `sendMessage`. Replay is keyed by the Safe transaction hash.
    function _runMessage(SignedDelivery memory d) private {
        SignedCalls.requireSourceCall(d.safeTx, sourceTransmitter);
        (bytes memory recipient, bytes memory payload,) = SignedCalls.sendMessageArgs(d.safeTx.data);
        SignedCalls.requireDestination(recipient, address(this));
        bytes32 safeTxHash = _verify(d);

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

    /// @dev R3 to R16 for a leaf under a signed `registerRoot`.
    function _runLeaf(SignedDelivery memory registration, ExecutionLeaf memory leaf, bytes32[] memory proof) private {
        SignedCalls.requireSourceCall(registration.safeTx, sourceTransmitter);
        bytes32 root = SignedCalls.registeredRoot(registration.safeTx.data);
        SignedCalls.requireDestination(leaf.destination, address(this));
        DispatchLeaves.requireProof(proof, root, DispatchLeaves.hash(leaf));
        _verify(registration);

        SignedReceiverStorage storage $ = _signedStorage();
        bytes32 id = DispatchLeaves.executionId(leaf);
        bytes32 stored = $.executions[leaf.nonce];
        // An executed batch is acknowledged silently, at any time and under any root.
        if (stored == id) return;
        if (stored != bytes32(0)) revert ConflictingLeaf(leaf.nonce);
        if (leaf.nonce != $.nextNonce) revert NonceNotNext(leaf.nonce, $.nextNonce);
        SignedCalls.requireOpen(leaf.validAfter, leaf.deadline);

        $.executions[leaf.nonce] = id;
        $.nextNonce = leaf.nonce + 1;
        emit LeafExecuted(leaf.nonce, id);
        Call[] memory calls = Payload.decodeCallsFromMemory(leaf.calls);
        emit Delivered(calls.length);
        _execute(calls);
    }

    /// @dev The source Safe's transaction hash over the exact calldata, with its signatures
    ///      verified against the stored authority.
    function _verify(SignedDelivery memory d) private view returns (bytes32 safeTxHash) {
        Authority storage authority = _signedStorage().authority;
        safeTxHash = SafeHashes.transactionHash(d.safeTx, authority.root, authority.sourceChainId);
        authority.verify(safeTxHash, d.signatures, d.nestedApprovals);
    }

    /* =================================== access ================================= */

    /// @dev In signed mode only this receiver's own calls, made inside verified execution.
    function isAuthorizedCaller(address conduit) public view override returns (bool) {
        if (_isSigned()) return conduit == address(this);
        return super.isAuthorizedCaller(conduit);
    }

    /* =================================== views ================================== */

    /// @notice The graph hash this receiver's address commits to; zero for a plain receiver.
    function authorityGraph() external view returns (bytes32) {
        return _signedStorage().graph;
    }

    /// @notice The stored authority in canonical order, which hashes to `authorityGraph`.
    function authorityRecords() external view returns (SafeRecord[] memory) {
        return _signedStorage().authority.readRecords();
    }

    /// @notice The local nonce the next new leaf must carry.
    function nextNonce() external view returns (uint256) {
        return _signedStorage().nextNonce;
    }

    /// @notice The execution ID recorded at `nonce`, or zero.
    function executionAt(uint256 nonce) external view returns (bytes32) {
        return _signedStorage().executions[nonce];
    }

    /// @notice Whether the standalone message with this Safe transaction hash has executed.
    function isMessageExecuted(bytes32 safeTxHash) external view returns (bool) {
        return _signedStorage().messages[safeTxHash];
    }

    /// @notice The bootstrap leaf hash that initialized this receiver.
    function bootstrapLeaf() external view returns (bytes32) {
        return _signedStorage().bootstrapLeaf;
    }
}
