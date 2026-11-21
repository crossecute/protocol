// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AuthorityGraph, MAX_SAFE_OWNERS} from "crossecute/messaging/authority/AuthorityGraph.sol";
import {AuthorityRecognition} from "crossecute/messaging/authority/AuthorityRecognition.sol";
import {AuthorityUpdateEncoding} from "crossecute/messaging/authority/AuthorityUpdateEncoding.sol";
import {ChildUpdate} from "crossecute/messaging/authority/ChildUpdate.sol";
import {ReceiverAuthority} from "crossecute/messaging/authority/ReceiverAuthority.sol";
import {SafeAuthorityRecord, SafeOwner} from "crossecute/messaging/signed/types/SafeAuthorityTypes.sol";
import {NestedSafeApproval, SafeTxEvidence} from "crossecute/messaging/signed/types/SignedDispatchTypes.sol";
import {ISafe} from "safe-smart-account/interfaces/ISafe.sol";
import {SafeTx, SignedSafeTx} from "../ICrossecuteGuard.sol";
import {GuardDiscovery} from "../GuardDiscovery.sol";
import {SafeHashes} from "../SafeHashes.sol";
import {AuthoritySelection, AuthorityUpdate} from "./AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "./ISourceAuthorityGuard.sol";

/// @notice The source half of #109: per-Safe authority state, activation, linked updates and the
///         rules that keep an activated Safe's live owners equal to its selected root record.
/// @dev ReceiverAuthority verifies a supplied current graph against the stored selection hash.
///      Full records stay in receiver storage. This contract adds the executed heads of each Safe,
///      the Safe's live configuration, and the calls an activated Safe may make. A host calls
///      `_authorityPreHook` from its owner pre-hook and `_authorityPostHook` from its post-hook.
///      The three source calls are markers: the pre-hook does the work and the call only proves,
///      for the calling Safe, that its transaction was recognized.
abstract contract SourceAuthorityGuard is ISourceAuthorityGuard {
    /// @dev Fixed at deployment, with no setter (X13). A zero singleton pin is unused.
    struct Pins {
        address multiSendCallOnly;
        address signMessageLib;
        address singleton;
        address singletonL2;
        address fallbackHandler;
    }

    struct StagedUpdate {
        AuthorityGraph currentGraph;
        AuthorityGraph newGraph;
        ChildUpdate[] childUpdates;
        bytes portableSignatures;
        NestedSafeApproval[] nestedApprovals;
    }

    bytes32 private constant NAMESPACE = keccak256("crossecute.guard.authority");
    uint256 private constant GUARD_SLOT = GuardDiscovery.GUARD_STORAGE_SLOT;
    uint256 private constant MODULE_GUARD_SLOT = 0xb104e0b93118902c651344349b610029d694cfdec91c589c91ebafbcd0289947;
    uint256 private constant FALLBACK_HANDLER_SLOT = 0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;
    address private constant SENTINEL = address(1);

    // Words of a Safe's live-update record. `_LIVE_HASH` is nonzero exactly while it is live.
    uint256 private constant _LIVE_HASH = 0;
    uint256 private constant _LIVE_KIND = 1;
    uint256 private constant _LIVE_OWNERS = 2;

    address internal immutable MULTISEND_CALL_ONLY;
    address internal immutable SIGN_MESSAGE_LIB;
    address private immutable _SINGLETON;
    address private immutable _SINGLETON_L2;
    address private immutable _FALLBACK_HANDLER;

    // solhint-disable-next-line private-vars-leading-underscore
    mapping(address safe => AuthoritySelection) private $authority;
    /// @dev The record hash of each head a Safe executed. Written only when its update executes.
    // solhint-disable-next-line private-vars-leading-underscore
    mapping(address safe => mapping(bytes32 head => bytes32 recordHash)) private $heads;

    // solhint-disable-next-line private-vars-leading-underscore
    mapping(address safe => mapping(bytes32 head => bytes32 submissionHash)) public publishedAuthority;

    error SafeBusy(address safe);
    error NotActivated(address safe);
    error AlreadyActivated(address safe);
    error NoStagedUpdate(address safe);
    error UnexpectedAuthorityCall(address safe);
    error ActivationChildUpdates();
    error GuardNotInstalled(uint256 slot);
    error UnrecognizedSingleton(address singleton);
    error UnrecognizedHandler(address handler);
    error ModulesEnabled();
    error OwnersMismatch();
    error PositionNotExecuted(address safe, bytes32 position);
    error SelfCallDenied();
    error DelegatecallDenied(address target);
    error OrdinaryBatchDenied();
    error FinalOwnersMismatch();
    error AuthorityHashMismatch(bytes32 live, bytes32 txHash);

    constructor(Pins memory pins) {
        MULTISEND_CALL_ONLY = pins.multiSendCallOnly;
        SIGN_MESSAGE_LIB = pins.signMessageLib;
        _SINGLETON = pins.singleton;
        _SINGLETON_L2 = pins.singletonL2;
        _FALLBACK_HANDLER = pins.fallbackHandler;
    }

    /// @inheritdoc ISourceAuthorityGuard
    function selection(address sourceSafe) external view returns (AuthoritySelection memory) {
        return $authority[sourceSafe];
    }

    /// @inheritdoc ISourceAuthorityGuard
    function executed(address sourceSafe, bytes32 updateHead) external view returns (bool) {
        return $heads[sourceSafe][updateHead] != bytes32(0);
    }

    /// @inheritdoc ISourceAuthorityGuard
    /// @dev Staging rejects during any owner execution under the per-Safe lock (X10).
    ///      A later stage replaces an earlier unconsumed one.
    function stageUpdate(
        address sourceSafe,
        AuthorityGraph calldata currentGraph,
        AuthorityGraph calldata newGraph,
        ChildUpdate[] calldata childUpdates,
        bytes calldata portableSignatures,
        NestedSafeApproval[] calldata nestedApprovals
    ) external {
        if (_authorityLive(sourceSafe) || _executionLive(sourceSafe)) {
            revert SafeBusy(sourceSafe);
        }
        _tstoreBytes(
            _stageId(sourceSafe),
            abi.encode(StagedUpdate(currentGraph, newGraph, childUpdates, portableSignatures, nestedApprovals))
        );
    }

    /// @inheritdoc ISourceAuthorityGuard
    function activate(bytes32) external view {
        _requireMarker(ReceiverAuthority.UpdateKind.Activation);
    }

    /// @inheritdoc ISourceAuthorityGuard
    function registerOwnershipChange(AuthorityUpdate calldata) external view {
        _requireMarker(ReceiverAuthority.UpdateKind.OwnershipChange);
    }

    /// @inheritdoc ISourceAuthorityGuard
    function selectAuthority(AuthorityUpdate calldata) external view {
        _requireMarker(ReceiverAuthority.UpdateKind.Selection);
    }

    /// @dev Whether the host has a live owner execution for `safe`.
    function _executionLive(address safe) internal view virtual returns (bool);

    function _activated(address safe) internal view returns (bool) {
        return $authority[safe].authorityHash != bytes32(0);
    }

    function _authorityLive(address safe) internal view returns (bool) {
        return _tload(_liveId(safe), _LIVE_HASH) != 0;
    }

    /// @dev Handles an owner transaction of the calling Safe. Returns true for an activation,
    ///      ownership change or selectAuthority, which the host then stages nothing for. Any other
    ///      transaction of an activated Safe must stay inside the calls that cannot change its
    ///      owners.
    function _authorityPreHook(SafeTx memory safeTx) internal returns (bool isUpdate) {
        address safe = msg.sender;
        AuthoritySelection storage selected = $authority[safe];
        bool activated = selected.authorityHash != bytes32(0);
        if (!_isAuthorityCall(safeTx)) {
            if (safeTx.to == MULTISEND_CALL_ONLY) revert OrdinaryBatchDenied();
            if (activated) _requireInsideProtectedCalls(safe, safeTx);
            return false;
        }
        ReceiverAuthority.RecognizedUpdate memory recognized = AuthorityRecognition.recognize(
            AuthorityRecognition.Context(address(this), MULTISEND_CALL_ONLY, safe), safeTx
        );
        StagedUpdate memory staged = _consumeStage(safe);
        AuthorityGraph memory newGraph = staged.newGraph;
        ChildUpdate[] memory childUpdates = staged.childUpdates;
        SafeTxEvidence memory evidence =
            SafeTxEvidence(SignedSafeTx(safeTx, staged.portableSignatures), staged.nestedApprovals);

        bytes32 updateHash;
        if (recognized.kind == ReceiverAuthority.UpdateKind.Activation) {
            if (activated) revert AlreadyActivated(safe);
            if (childUpdates.length != 0) revert ActivationChildUpdates();
            _requireSupportedConfiguration(safe);
            _requireNamedPositionsExecuted(newGraph);
            updateHash = ReceiverAuthority.requireActivation(
                block.chainid, safe, evidence, newGraph, _liveRecord(safe, newGraph.nodes[0].record), recognized
            );
        } else {
            if (!activated) revert NotActivated(safe);
            _requireNamedPositionsExecuted(newGraph);
            ReceiverAuthority.Recognized memory all;
            all.root = recognized;
            all.children = new ReceiverAuthority.RecognizedUpdate[](childUpdates.length);
            for (uint256 i = 0; i < childUpdates.length; ++i) {
                SafeTx memory childTx = childUpdates[i].evidence.signedSafeTx.safeTx;
                address child = childUpdates[i].sourceSafe;
                // forge-lint: disable-start(calls-loop) pure decoder in the fixed linked library
                all.children[i] = AuthorityRecognition.recognize(
                    AuthorityRecognition.Context(address(this), MULTISEND_CALL_ONLY, child), childTx
                );
                // forge-lint: disable-end(calls-loop)
                bytes32 position = SafeHashes.transactionHash(childTx, child, block.chainid);
                if ($heads[child][position] != AuthorityUpdateEncoding.recordHash(childUpdates[i].newRecord)) {
                    revert PositionNotExecuted(child, position);
                }
            }
            updateHash = ReceiverAuthority.requireUpdate(
                selected,
                staged.currentGraph,
                ReceiverAuthority.UpdateRequest(block.chainid, safe, evidence, newGraph, childUpdates, all)
            );
        }
        selected.updateHead = updateHash;
        selected.authorityHash = recognized.update.newAuthorityHash;
        $heads[safe][updateHash] = AuthorityUpdateEncoding.recordHash(newGraph.nodes[0].record);
        _tstoreLive(safe, updateHash, recognized.kind, newGraph.nodes[0].record);
        if (recognized.kind != ReceiverAuthority.UpdateKind.Activation) {
            bytes memory submission = abi.encode(evidence, newGraph, childUpdates);
            publishedAuthority[safe][updateHash] = keccak256(submission);
            // forge-lint: disable-next-line(reentrancy-events) preceding calls are linked verification and static Safe reads
            emit AuthorityPublished(safe, updateHash, submission);
        }
        // forge-lint: disable-start(reentrancy-events) fixed verification and Safe staticcalls run under the owner-execution lock
        emit AuthorityUpdateExecuted(
            safe, updateHash, selected.authorityHash, staged.portableSignatures, staged.nestedApprovals
        );
        // forge-lint: disable-end(reentrancy-events)
        return true;
    }

    /// @dev The calling Safe's post-hook. For a live update, the executed transaction must be the
    ///      one recognized and the Safe's final owners and threshold must match the recognized
    ///      root record, or the whole Safe transaction reverts.
    function _authorityPostHook(bytes32 txHash) internal {
        address safe = msg.sender;
        bytes32 id = _liveId(safe);
        bytes32 live = bytes32(_tload(id, _LIVE_HASH));
        if (live == bytes32(0)) return;
        if (live != txHash) revert AuthorityHashMismatch(live, txHash);
        if (_tload(id, _LIVE_OWNERS) != uint256(_ownersHash(safe))) revert FinalOwnersMismatch();
        _tstore(id, _LIVE_HASH, 0);
        _tstore(id, _LIVE_KIND, 0);
        _tstore(id, _LIVE_OWNERS, 0);
    }

    function _isAuthorityCall(SafeTx memory safeTx) private view returns (bool) {
        if (safeTx.to == address(this)) {
            if (safeTx.data.length < 4) return false;
            // forge-lint: disable-next-line(unsafe-typecast) the first four bytes, after the length check
            bytes4 selector = bytes4(safeTx.data);
            return selector == ISourceAuthorityGuard.activate.selector
                || selector == ISourceAuthorityGuard.selectAuthority.selector;
        }
        return safeTx.to == MULTISEND_CALL_ONLY && safeTx.operation == 1
            && AuthorityUpdateEncoding.isOwnershipBatch(address(this), safeTx.data);
    }

    /// @dev Ordinary MultiSend calls reject before this check. An activated Safe may neither call
    ///      itself nor delegatecall anything but the pinned signing library outside an update.
    ///      Together these keep owners, threshold, guards, handler, modules and singleton fixed
    ///      outside a recognized update.
    function _requireInsideProtectedCalls(address safe, SafeTx memory safeTx) private view {
        if (safeTx.to == safe) revert SelfCallDenied();
        if (safeTx.operation == 0) return;
        if (safeTx.to != SIGN_MESSAGE_LIB) {
            revert DelegatecallDenied(safeTx.to);
        }
    }

    /// @dev X11: both guard slots hold this guard, the singleton and handler are pinned, and no
    ///      module is enabled. With self-calls denied afterwards, none can be enabled later.
    function _requireSupportedConfiguration(address safe) private view {
        if (GuardDiscovery.storageWord(safe, GUARD_SLOT) != uint256(uint160(address(this)))) {
            revert GuardNotInstalled(GUARD_SLOT);
        }
        if (GuardDiscovery.storageWord(safe, MODULE_GUARD_SLOT) != uint256(uint160(address(this)))) {
            revert GuardNotInstalled(MODULE_GUARD_SLOT);
        }
        // forge-lint: disable-next-line(unsafe-typecast) a Safe's singleton slot holds an address
        address singleton = address(uint160(GuardDiscovery.storageWord(safe, 0)));
        if (singleton == address(0) || (singleton != _SINGLETON && singleton != _SINGLETON_L2)) {
            revert UnrecognizedSingleton(singleton);
        }
        // forge-lint: disable-next-line(unsafe-typecast) a Safe's handler slot holds an address
        address handler = address(uint160(GuardDiscovery.storageWord(safe, FALLBACK_HANDLER_SLOT)));
        if (handler == address(0) || handler != _FALLBACK_HANDLER) revert UnrecognizedHandler(handler);
        // forge-lint: disable-next-line(unused-return) one module is enough to refuse
        (address[] memory modules,) = ISafe(payable(safe)).getModulesPaginated(SENTINEL, 1);
        if (modules.length != 0) revert ModulesEnabled();
    }

    /// @dev The Safe's live owners and threshold with the kinds `initial`'s root record names.
    function _liveRecord(address safe, SafeAuthorityRecord memory named)
        private
        view
        returns (SafeAuthorityRecord memory live)
    {
        address[] memory owners = ISafe(payable(safe)).getOwners();
        if (owners.length != named.owners.length || owners.length > MAX_SAFE_OWNERS) revert OwnersMismatch();
        live.safe = safe;
        live.threshold = ISafe(payable(safe)).getThreshold();
        live.owners = new SafeOwner[](owners.length);
        for (uint256 i = 0; i < owners.length; ++i) {
            if (owners[i] != named.owners[i].owner) revert OwnersMismatch();
            live.owners[i] = named.owners[i];
        }
    }

    /// @dev Every non-root node is a position its Safe executed, with the node's record there.
    function _requireNamedPositionsExecuted(AuthorityGraph memory graph) private view {
        for (uint256 i = 1; i < graph.nodes.length; ++i) {
            address child = graph.nodes[i].record.safe;
            bytes32 position = graph.nodes[i].position;
            if ($heads[child][position] != AuthorityUpdateEncoding.recordHash(graph.nodes[i].record)) {
                revert PositionNotExecuted(child, position);
            }
        }
    }

    function _requireMarker(ReceiverAuthority.UpdateKind kind) private view {
        bytes32 id = _liveId(msg.sender);
        if (_tload(id, _LIVE_HASH) == 0 || _tload(id, _LIVE_KIND) != uint256(kind) + 1) {
            revert UnexpectedAuthorityCall(msg.sender);
        }
    }

    function _tstoreLive(
        address safe,
        bytes32 updateHash,
        ReceiverAuthority.UpdateKind kind,
        SafeAuthorityRecord memory root
    ) private {
        bytes32 id = _liveId(safe);
        _tstore(id, _LIVE_HASH, uint256(updateHash));
        _tstore(id, _LIVE_KIND, uint256(kind) + 1);
        _tstore(id, _LIVE_OWNERS, uint256(_recordOwnersHash(root)));
    }

    /// @dev Addresses and threshold only: the Safe stores no owner kinds.
    function _recordOwnersHash(SafeAuthorityRecord memory record) private pure returns (bytes32) {
        address[] memory owners = new address[](record.owners.length);
        for (uint256 i = 0; i < owners.length; ++i) {
            owners[i] = record.owners[i].owner;
        }
        return keccak256(abi.encode(record.threshold, owners));
    }

    function _ownersHash(address safe) private view returns (bytes32) {
        return keccak256(abi.encode(ISafe(payable(safe)).getThreshold(), ISafe(payable(safe)).getOwners()));
    }

    function _consumeStage(address safe) private returns (StagedUpdate memory) {
        bytes memory staged = _tloadBytes(_stageId(safe));
        if (staged.length == 0) revert NoStagedUpdate(safe);
        _tstoreBytes(_stageId(safe), "");
        return abi.decode(staged, (StagedUpdate));
    }

    function _liveId(address safe) private pure returns (bytes32) {
        return keccak256(abi.encode(safe, NAMESPACE, "live"));
    }

    function _stageId(address safe) private pure returns (bytes32) {
        return keccak256(abi.encode(safe, NAMESPACE, "stage"));
    }

    /// @dev Length word, then the bytes in words. A shorter replacement leaves earlier words
    ///      behind, which no read reaches.
    function _tstoreBytes(bytes32 id, bytes memory data) private {
        _tstore(id, 0, data.length);
        for (uint256 i = 0; i < data.length; i += 32) {
            uint256 word;
            assembly ("memory-safe") {
                word := mload(add(add(data, 0x20), i))
            }
            _tstore(id, 1 + (i >> 5), word);
        }
    }

    function _tloadBytes(bytes32 id) private view returns (bytes memory data) {
        uint256 length = _tload(id, 0);
        data = new bytes(length);
        for (uint256 i = 0; i < length; i += 32) {
            uint256 word = _tload(id, 1 + (i >> 5));
            assembly ("memory-safe") {
                mstore(add(add(data, 0x20), i), word)
            }
        }
    }

    function _tload(bytes32 id, uint256 offset) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(add(id, offset))
        }
    }

    function _tstore(bytes32 id, uint256 offset, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(add(id, offset), value)
        }
    }
}
