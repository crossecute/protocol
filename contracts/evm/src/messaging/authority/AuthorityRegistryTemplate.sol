// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {AuthoritySelection, AuthorityUpdate} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {SafeAuthorityRecord} from "../signed/types/SafeAuthorityTypes.sol";
import {SafeTxEvidence} from "../signed/types/SignedDispatchTypes.sol";
import {AuthorityEntry, AuthorityGraph, AuthorityNode} from "./AuthorityGraph.sol";
import {ChildUpdate} from "./ChildUpdate.sol";
import {AuthorityUpdateEncoding} from "./AuthorityUpdateEncoding.sol";
import {IAuthorityRegistry} from "./IAuthorityRegistry.sol";

/// @notice Non-deployable linked-update state-machine template for #109.
/// @dev Mandatory abstract hooks cover source calls, creation proofs, graph and child proofs and
///      signatures. Current receivers do not read this state. Concrete integration must freeze
///      the shared context throughout application execution. This is absent from deployment
///      scripts.
abstract contract AuthorityRegistryTemplate is IAuthorityRegistry {
    enum UpdateKind {
        Activation,
        OwnershipChange,
        Selection
    }

    mapping(uint256 => mapping(address => AuthoritySelection)) private _selections;
    // Content-addressed: a record shared by several graphs or kept across updates is written once.
    mapping(bytes32 => bytes) private _records;
    mapping(bytes32 => AuthorityEntry[]) private _graphs;
    bool private _submitting;

    error UnregisteredAuthority();
    error AlreadyRegistered();
    error WrongRoot();
    error RootPositionNotZero();
    error ZeroCommitment();
    error PreviousUpdateMismatch();
    error ReplacementHashMismatch();
    error AuthoritySubmissionReentered();
    error GraphNotCached();
    error RecordNotCached();

    /// @inheritdoc IAuthorityRegistry
    function selection(uint256 sourceChainId, address sourceSafe) public view returns (AuthoritySelection memory) {
        return _selections[sourceChainId][sourceSafe];
    }

    /// @inheritdoc IAuthorityRegistry
    function graph(bytes32 authorityHash) public view returns (AuthorityGraph memory authority) {
        AuthorityEntry[] storage stored = _graphs[authorityHash];
        if (stored.length == 0) revert GraphNotCached();
        authority.nodes = new AuthorityNode[](stored.length);
        for (uint256 i; i < stored.length; ++i) {
            authority.nodes[i] = AuthorityNode(record(stored[i].recordHash), stored[i].position);
        }
    }

    /// @inheritdoc IAuthorityRegistry
    function record(bytes32 recordHash) public view returns (SafeAuthorityRecord memory) {
        bytes storage encoded = _records[recordHash];
        if (encoded.length == 0) revert RecordNotCached();
        return abi.decode(encoded, (SafeAuthorityRecord));
    }

    /// @inheritdoc IAuthorityRegistry
    function submitAuthority(
        uint256 sourceChainId,
        address sourceSafe,
        SafeTxEvidence calldata evidence,
        AuthorityGraph calldata newGraph,
        ChildUpdate[] calldata childUpdates
    ) external {
        if (_submitting) revert AuthoritySubmissionReentered();
        _submitting = true;
        _requireAuthorityContextIdle(sourceChainId, sourceSafe);
        _requireRoot(sourceSafe, newGraph);
        bytes32 updateHash = SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, sourceSafe, sourceChainId);
        if (updateHash == bytes32(0)) revert ZeroCommitment();

        AuthoritySelection memory current = _selections[sourceChainId][sourceSafe];
        (UpdateKind kind, AuthorityUpdate memory update) = _recognizeUpdate(sourceChainId, sourceSafe, evidence);
        if (current.authorityHash == bytes32(0)) {
            if (kind != UpdateKind.Activation) revert UnregisteredAuthority();
        } else {
            if (kind == UpdateKind.Activation) revert AlreadyRegistered();
            // Also the replay check: each head commits to its predecessor, so heads never repeat
            // and an accepted update cannot match the stored head again.
            if (update.previousUpdateHash != current.updateHead) revert PreviousUpdateMismatch();
        }
        if (update.newAuthorityHash == bytes32(0)) revert ZeroCommitment();
        AuthorityEntry[] memory newEntries = AuthorityUpdateEncoding.entries(newGraph);
        if (AuthorityUpdateEncoding.graphHash(sourceChainId, newEntries) != update.newAuthorityHash) {
            revert ReplacementHashMismatch();
        }
        // Signatures are checked after the graph because each descendant votes under the
        // position newGraph names for it. No default verification implementation exists.
        _authenticateGraph(sourceChainId, current.authorityHash, kind, evidence, newGraph, childUpdates);
        _verifyUpdateSignatures(sourceChainId, current.authorityHash, kind, evidence, newGraph);

        // Validation precedes writes. Any revert rolls back the lock too.
        _store(newGraph, newEntries, update.newAuthorityHash);
        _selections[sourceChainId][sourceSafe] = AuthoritySelection(updateHash, update.newAuthorityHash);
        emit AuthoritySelected(sourceChainId, sourceSafe, updateHash, update.newAuthorityHash);
        _submitting = false;
    }

    function _requireRoot(address sourceSafe, AuthorityGraph calldata authority) private pure {
        if (sourceSafe == address(0) || authority.nodes.length == 0 || authority.nodes[0].record.safe != sourceSafe) {
            revert WrongRoot();
        }
        if (authority.nodes[0].position != bytes32(0)) revert RootPositionNotZero();
    }

    function _store(AuthorityGraph calldata authority, AuthorityEntry[] memory graphEntries, bytes32 authorityHash)
        private
    {
        for (uint256 i; i < graphEntries.length; ++i) {
            bytes storage stored = _records[graphEntries[i].recordHash];
            // forge-lint: disable-next-line(costly-loop) one write per record not stored yet
            if (stored.length == 0) _records[graphEntries[i].recordHash] = abi.encode(authority.nodes[i].record);
        }
        // A graph returning to an earlier hash is already stored under it.
        AuthorityEntry[] storage graphSlot = _graphs[authorityHash];
        if (graphSlot.length != 0) return;
        for (uint256 i; i < graphEntries.length; ++i) {
            graphSlot.push(graphEntries[i]);
        }
    }

    /// @dev Recognize the signed source call and return its kind and update. An activation
    ///      returns a zero previousUpdateHash and its signed graph hash. No signature check.
    function _recognizeUpdate(uint256 sourceChainId, address sourceSafe, SafeTxEvidence calldata evidence)
        internal
        view
        virtual
        returns (UpdateKind kind, AuthorityUpdate memory update);

    /// @dev Check canonical acyclic structure, 16 owners per Safe and kinds/thresholds; no extra
    ///      work caps. The root's new record is its creation record for an activation (verified
    ///      from the signed creation proof), its stored record after the signed mutations for an
    ///      ownership change, and its stored record for a selection. Descendant positions are
    ///      proven in one flat pass over childUpdates, seeded with the graph stored under
    ///      currentAuthorityHash (empty for an activation) and with supplied activations: each
    ///      child update needs its predecessor and its nested voters' positions already proven.
    ///      A retained descendant's position must descend from its stored one.
    function _authenticateGraph(
        uint256 sourceChainId,
        bytes32 currentAuthorityHash,
        UpdateKind kind,
        SafeTxEvidence calldata evidence,
        AuthorityGraph calldata newGraph,
        ChildUpdate[] calldata childUpdates
    ) internal view virtual;

    /// @dev Full portable quorum. The root votes under its record in the graph stored under
    ///      currentAuthorityHash, or under its creation record for an activation; each
    ///      descendant votes under its record in the authenticated new graph.
    function _verifyUpdateSignatures(
        uint256 sourceChainId,
        bytes32 currentAuthorityHash,
        UpdateKind kind,
        SafeTxEvidence calldata evidence,
        AuthorityGraph calldata newGraph
    ) internal view virtual;

    /// @dev Concrete integration must share application-execution locking across providers.
    function _requireAuthorityContextIdle(uint256 sourceChainId, address sourceSafe) internal view virtual;
}
