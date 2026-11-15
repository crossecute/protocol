// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {
    AuthoritySelection,
    AuthorityUpdate,
    SafeCreationProof
} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {Call} from "../Call.sol";
import {SafeAuthorityGraph} from "../signed/SafeAuthorityGraph.sol";
import {OWNER_SAFE, SafeAuthorityRecord} from "../signed/types/SafeAuthorityTypes.sol";
import {SafeTxEvidence} from "../signed/types/SignedDispatchTypes.sol";
import {AuthorityEntry, AuthorityGraph, AuthorityNode, MAX_SAFE_OWNERS} from "./AuthorityGraph.sol";
import {AuthorityMutations} from "./AuthorityMutations.sol";
import {ChildUpdate} from "./ChildUpdate.sol";
import {AuthorityUpdateEncoding} from "./AuthorityUpdateEncoding.sol";
import {IAuthorityRegistry} from "./IAuthorityRegistry.sol";
import {SafeCreation} from "./SafeCreation.sol";

/// @notice Non-deployable linked-update state-machine template for #109.
/// @dev Owns graph authentication: canonical structure, each update kind's root record and the
///      flat child-update pass. Source-call recognition, votes and context locking are abstract
///      hooks. Current receivers do not read this state. Concrete integration must freeze the
///      shared context throughout application execution. This is absent from deployment
///      scripts.
abstract contract AuthorityRegistryTemplate is IAuthorityRegistry {
    enum UpdateKind {
        Activation,
        OwnershipChange,
        Selection
    }

    /// @dev A recognized source call. mutations is set for an ownership change, creation for an
    ///      activation.
    struct RecognizedUpdate {
        UpdateKind kind;
        AuthorityUpdate update;
        Call[] mutations;
        SafeCreationProof creation;
    }

    /// @dev A (Safe, position) whose record the pass has proven. fromStored: reached from the
    ///      stored graph, not from a supplied activation.
    struct ProvenPosition {
        address safe;
        bytes32 position;
        bytes32 recordHash;
        SafeAuthorityRecord record;
        bool fromStored;
        bool used;
    }

    struct ProvenTable {
        ProvenPosition[] rows;
        uint256 count;
    }

    /// @dev Where a vote hook finds nested Safe voters: the voting update's new graph entries,
    ///      each matched against proven rows.
    struct VoterPositions {
        ProvenTable table;
        AuthorityEntry[] entries;
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
    error TooManyGraphOwners(address safe);
    error RootRecordMismatch();
    error ChildRecordMismatch(uint256 index);
    error ChildGraphHashMismatch(uint256 index);
    error UnprovenPredecessor(uint256 index);
    error RepeatedChildUpdate(uint256 index);
    error UnusedChildUpdate(uint256 index);
    error UnprovenPosition(address safe);
    error DescendantRecordMismatch(address safe);
    error RetainedPositionNotDescended(address safe);
    error UnprovenVoter(address safe);

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
        RecognizedUpdate memory recognized = _recognizeUpdate(sourceChainId, sourceSafe, evidence);
        AuthorityUpdate memory update = recognized.update;
        if (current.authorityHash == bytes32(0)) {
            if (recognized.kind != UpdateKind.Activation) revert UnregisteredAuthority();
        } else {
            if (recognized.kind == UpdateKind.Activation) revert AlreadyRegistered();
            // Also the replay check: each head commits to its predecessor, so heads never repeat
            // and an accepted update cannot match the stored head again.
            if (update.previousUpdateHash != current.updateHead) revert PreviousUpdateMismatch();
        }
        if (update.newAuthorityHash == bytes32(0)) revert ZeroCommitment();
        AuthorityEntry[] memory newEntries = AuthorityUpdateEncoding.entries(newGraph);
        if (AuthorityUpdateEncoding.graphHash(sourceChainId, newEntries) != update.newAuthorityHash) {
            revert ReplacementHashMismatch();
        }
        _authenticate(sourceChainId, current.authorityHash, recognized, evidence, newGraph, newEntries, childUpdates);

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

    /// @dev Checks newGraph's structure and root record, proves every descendant position in one
    ///      flat pass over childUpdates, then the root's votes. Signatures follow the graph because
    ///      each descendant votes under the position newGraph names for it.
    function _authenticate(
        uint256 sourceChainId,
        bytes32 currentAuthorityHash,
        RecognizedUpdate memory recognized,
        SafeTxEvidence calldata evidence,
        AuthorityGraph calldata newGraph,
        AuthorityEntry[] memory newEntries,
        ChildUpdate[] calldata childUpdates
    ) private view {
        SafeAuthorityRecord[] memory records = _requireCanonical(newGraph);
        // Empty for an activation: zero is never a stored graph hash.
        AuthorityEntry[] storage stored = _graphs[currentAuthorityHash];
        ProvenTable memory table = ProvenTable(new ProvenPosition[](stored.length + childUpdates.length), 0);

        // The root votes under its creation record or its stored record, never the new one (T6).
        SafeAuthorityRecord memory voters;
        if (recognized.kind == UpdateKind.Activation) {
            SafeCreation.requireCreationRecord(sourceChainId, records[0], recognized.creation);
            voters = records[0];
        } else {
            voters = record(stored[0].recordHash);
            if (recognized.kind == UpdateKind.OwnershipChange) {
                AuthorityMutations.applyMutations(voters, recognized.mutations, records[0]);
            } else if (stored[0].recordHash != newEntries[0].recordHash) {
                revert RootRecordMismatch();
            }
            for (uint256 i = 1; i < stored.length; ++i) {
                SafeAuthorityRecord memory seed = record(stored[i].recordHash);
                table.rows[i - 1] =
                    ProvenPosition(seed.safe, stored[i].position, stored[i].recordHash, seed, true, true);
            }
            table.count = stored.length - 1;
        }

        uint256 seeds = table.count;
        for (uint256 i; i < childUpdates.length; ++i) {
            _proveChildUpdate(sourceChainId, table, childUpdates[i], i);
        }
        for (uint256 i = 1; i < records.length; ++i) {
            address safe = records[i].safe;
            uint256 at = _find(table, safe, newEntries[i].position);
            if (at == table.count) revert UnprovenPosition(safe);
            ProvenPosition memory row = table.rows[at];
            if (row.recordHash != newEntries[i].recordHash) revert DescendantRecordMismatch(safe);
            if (!row.fromStored && _isSeeded(table, seeds, safe)) revert RetainedPositionNotDescended(safe);
            row.used = true;
        }
        // Each child update adds one row, so row seeds + i is childUpdates[i].
        for (uint256 i = seeds; i < table.count; ++i) {
            if (!table.rows[i].used) revert UnusedChildUpdate(i - seeds);
        }
        _verifyVotes(sourceChainId, records[0].safe, evidence, voters, VoterPositions(table, newEntries));
    }

    /// @dev childUpdates[index] must extend a proven position of its Safe, or be its activation,
    ///      and add a position not yet proven. Its voters are its predecessor record, or its
    ///      creation record for an activation.
    function _proveChildUpdate(
        uint256 sourceChainId,
        ProvenTable memory table,
        ChildUpdate calldata child,
        uint256 index
    ) private view {
        address safe = child.sourceSafe;
        RecognizedUpdate memory recognized = _recognizeUpdate(sourceChainId, safe, child.evidence);
        AuthorityEntry[] memory entries = child.newGraphEntries;
        SafeAuthorityRecord memory newRecord = child.newRecord;
        bytes32 newRecordHash = AuthorityUpdateEncoding.recordHash(newRecord);
        if (newRecord.safe != safe || entries.length == 0 || entries[0].recordHash != newRecordHash) {
            revert ChildRecordMismatch(index);
        }
        if (AuthorityUpdateEncoding.graphHash(sourceChainId, entries) != recognized.update.newAuthorityHash) {
            revert ChildGraphHashMismatch(index);
        }

        SafeAuthorityRecord memory voters;
        bool fromStored;
        if (recognized.kind == UpdateKind.Activation) {
            _requireOwnerKinds(newRecord, index);
            SafeCreation.requireCreationRecord(sourceChainId, newRecord, recognized.creation);
            voters = newRecord;
        } else {
            uint256 at = _find(table, safe, recognized.update.previousUpdateHash);
            if (at == table.count) revert UnprovenPredecessor(index);
            ProvenPosition memory predecessor = table.rows[at];
            predecessor.used = true;
            voters = predecessor.record;
            fromStored = predecessor.fromStored;
            if (recognized.kind == UpdateKind.OwnershipChange) {
                _requireOwnerKinds(newRecord, index);
                AuthorityMutations.applyMutations(voters, recognized.mutations, newRecord);
            } else if (predecessor.recordHash != newRecordHash) {
                revert ChildRecordMismatch(index);
            }
        }

        bytes32 position = SafeHashes.transactionHash(child.evidence.signedSafeTx.safeTx, safe, sourceChainId);
        if (_find(table, safe, position) != table.count) revert RepeatedChildUpdate(index);
        _verifyVotes(sourceChainId, safe, child.evidence, voters, VoterPositions(table, entries));
        table.rows[table.count++] = ProvenPosition(safe, position, newRecordHash, newRecord, fromStored, false);
    }

    /// @notice The record a nested Safe voter counts under: its proven row at the position the
    ///         voting update's new graph names for it.
    /// @dev Marks the row used. A Safe owner the update removes has no named position, so it
    ///      cannot vote.
    function _voterRecord(VoterPositions memory positions, address safe)
        internal
        pure
        returns (SafeAuthorityRecord memory)
    {
        ProvenTable memory table = positions.table;
        AuthorityEntry[] memory entries = positions.entries;
        for (uint256 i; i < entries.length; ++i) {
            uint256 at = _find(table, safe, entries[i].position);
            if (at != table.count && table.rows[at].recordHash == entries[i].recordHash) {
                table.rows[at].used = true;
                return table.rows[at].record;
            }
        }
        revert UnprovenVoter(safe);
    }

    /// @dev #108's canonical acyclic traversal plus the 16-owner cap (D87).
    function _requireCanonical(AuthorityGraph calldata authority)
        private
        view
        returns (SafeAuthorityRecord[] memory records)
    {
        records = new SafeAuthorityRecord[](authority.nodes.length);
        for (uint256 i; i < records.length; ++i) {
            records[i] = authority.nodes[i].record;
            if (records[i].owners.length > MAX_SAFE_OWNERS) revert TooManyGraphOwners(records[i].safe);
        }
        SafeAuthorityGraph.requireCanonical(records);
    }

    /// @dev A child record that names new owners: the 16-owner cap and known kinds. Other group
    ///      rules follow from Safe setup or applyMutations.
    function _requireOwnerKinds(SafeAuthorityRecord memory childRecord, uint256 index) private pure {
        if (childRecord.owners.length > MAX_SAFE_OWNERS) revert ChildRecordMismatch(index);
        for (uint256 i; i < childRecord.owners.length; ++i) {
            if (childRecord.owners[i].kind > OWNER_SAFE) revert ChildRecordMismatch(index);
        }
    }

    /// @dev Returns table.count when absent.
    function _find(ProvenTable memory table, address safe, bytes32 position) private pure returns (uint256 i) {
        while (i < table.count && (table.rows[i].safe != safe || table.rows[i].position != position)) {
            ++i;
        }
    }

    function _isSeeded(ProvenTable memory table, uint256 seeds, address safe) private pure returns (bool) {
        for (uint256 i; i < seeds; ++i) {
            if (table.rows[i].safe == safe) return true;
        }
        return false;
    }

    /// @dev Recognize the signed source call of `sourceSafe`, the root or a child. An activation
    ///      returns a zero previousUpdateHash and its signed graph hash. No signature check.
    function _recognizeUpdate(uint256 sourceChainId, address sourceSafe, SafeTxEvidence calldata evidence)
        internal
        view
        virtual
        returns (RecognizedUpdate memory);

    /// @dev Full portable quorum of `voters` over safe's SafeTx in evidence. Nested Safe voters,
    ///      at any depth, count under _voterRecord(positions, ...).
    function _verifyVotes(
        uint256 sourceChainId,
        address safe,
        SafeTxEvidence calldata evidence,
        SafeAuthorityRecord memory voters,
        VoterPositions memory positions
    ) internal view virtual;

    /// @dev Concrete integration must share application-execution locking across providers.
    function _requireAuthorityContextIdle(uint256 sourceChainId, address sourceSafe) internal view virtual;
}
