// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {AuthoritySelection, AuthorityUpdate} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {Call} from "../Call.sol";
import {SafeAuthorityGraph} from "../signed/SafeAuthorityGraph.sol";
import {OwnerSource, SafeQuorum} from "../signed/SafeQuorum.sol";
import {OWNER_SAFE, SafeAuthorityRecord, SafeOwner} from "../signed/types/SafeAuthorityTypes.sol";
import {SafeTxEvidence} from "../signed/types/SignedDispatchTypes.sol";
import {AuthorityEntry, AuthorityGraph, AuthorityNode, MAX_SAFE_OWNERS} from "./AuthorityGraph.sol";
import {AuthorityMutations} from "./AuthorityMutations.sol";
import {ChildUpdate} from "./ChildUpdate.sol";
import {AuthorityUpdateEncoding} from "./AuthorityUpdateEncoding.sol";
import {IReceiverAuthority} from "./IReceiverAuthority.sol";

/// @notice Non-deployable linked-update state machine of one signed receiver (#109).
/// @dev Owns graph authentication: canonical structure, each update kind's root record, the
///      flat child-update pass and every update's votes. Source-call recognition, the source
///      identity and context locking are abstract hooks. The first selection is seeded from the
///      receiver's bootstrap; activations are never accepted. Current receivers do not read this
///      state, and it is absent from deployment scripts.
abstract contract ReceiverAuthorityTemplate is IReceiverAuthority {
    enum UpdateKind {
        Activation,
        OwnershipChange,
        Selection
    }

    /// @dev A recognized source call. mutations is set for an ownership change.
    struct RecognizedUpdate {
        UpdateKind kind;
        AuthorityUpdate update;
        Call[] mutations;
    }

    /// @dev A (Safe, position) whose record the pass has proven, from the stored graph or a
    ///      child update extending it.
    struct ProvenPosition {
        address safe;
        bytes32 position;
        bytes32 recordHash;
        SafeAuthorityRecord record;
        bool used;
    }

    struct ProvenTable {
        ProvenPosition[] rows;
        uint256 count;
    }

    /// @dev Where the vote check finds nested Safe voters: the voting update's new graph entries,
    ///      each matched against proven rows.
    struct VoterPositions {
        ProvenTable table;
        AuthorityEntry[] entries;
    }

    /// @dev The owner source of one vote check: `voters` for the voting Safe, `positions` for
    ///      every other Safe.
    struct VoteContext {
        address safe;
        SafeAuthorityRecord voters;
        VoterPositions positions;
    }

    AuthoritySelection private _selection;
    // Content-addressed: a record shared by several graphs or kept across updates is written once.
    mapping(bytes32 => bytes) private _records;
    mapping(bytes32 => AuthorityEntry[]) private _graphs;
    bool private _submitting;

    error UnseededAuthority();
    error AlreadySeeded();
    error ActivationNotAccepted();
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
    error UnprovenVoter(address safe);

    /// @inheritdoc IReceiverAuthority
    function selection() public view returns (AuthoritySelection memory) {
        return _selection;
    }

    /// @inheritdoc IReceiverAuthority
    function graph(bytes32 authorityHash) public view returns (AuthorityGraph memory authority) {
        AuthorityEntry[] storage stored = _graphs[authorityHash];
        if (stored.length == 0) revert GraphNotCached();
        authority.nodes = new AuthorityNode[](stored.length);
        for (uint256 i; i < stored.length; ++i) {
            authority.nodes[i] = AuthorityNode(record(stored[i].recordHash), stored[i].position);
        }
    }

    /// @inheritdoc IReceiverAuthority
    function record(bytes32 recordHash) public view returns (SafeAuthorityRecord memory) {
        bytes storage encoded = _records[recordHash];
        if (encoded.length == 0) revert RecordNotCached();
        return abi.decode(encoded, (SafeAuthorityRecord));
    }

    /// @notice Store the head and selected graph a bootstrap carried, once.
    /// @dev Taken on the provider's authentication of the bootstrap (#148): signatures cannot
    ///      prove a carried graph. Shape checks still apply.
    function _seedAuthority(bytes32 updateHead, AuthorityGraph calldata initial) internal {
        if (_selection.authorityHash != bytes32(0)) revert AlreadySeeded();
        if (updateHead == bytes32(0)) revert ZeroCommitment();
        (uint256 sourceChainId, address sourceSafe) = _authoritySource();
        _requireRoot(sourceSafe, initial);
        _requireCanonical(initial);
        AuthorityEntry[] memory entries = AuthorityUpdateEncoding.entries(initial);
        for (uint256 i = 1; i < entries.length; ++i) {
            if (entries[i].position == bytes32(0)) revert UnprovenPosition(initial.nodes[i].record.safe);
        }
        bytes32 authorityHash = AuthorityUpdateEncoding.graphHash(sourceChainId, entries);
        _store(initial, entries, authorityHash);
        _selection = AuthoritySelection(updateHead, authorityHash);
        emit AuthoritySelected(updateHead, authorityHash);
    }

    /// @inheritdoc IReceiverAuthority
    function submitAuthority(
        SafeTxEvidence calldata evidence,
        AuthorityGraph calldata newGraph,
        ChildUpdate[] calldata childUpdates
    ) external {
        if (_submitting) revert AuthoritySubmissionReentered();
        _submitting = true;
        _requireAuthorityContextIdle();
        (uint256 sourceChainId, address sourceSafe) = _authoritySource();
        _requireRoot(sourceSafe, newGraph);
        bytes32 updateHash = SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, sourceSafe, sourceChainId);
        if (updateHash == bytes32(0)) revert ZeroCommitment();

        AuthoritySelection memory current = _selection;
        if (current.authorityHash == bytes32(0)) revert UnseededAuthority();
        RecognizedUpdate memory recognized = _recognizeUpdate(sourceChainId, sourceSafe, evidence);
        if (recognized.kind == UpdateKind.Activation) revert ActivationNotAccepted();
        AuthorityUpdate memory update = recognized.update;
        // Also the replay check: each head commits to its predecessor, so heads never repeat
        // and an accepted update cannot match the stored head again.
        if (update.previousUpdateHash != current.updateHead) revert PreviousUpdateMismatch();
        if (update.newAuthorityHash == bytes32(0)) revert ZeroCommitment();
        AuthorityEntry[] memory newEntries = AuthorityUpdateEncoding.entries(newGraph);
        if (AuthorityUpdateEncoding.graphHash(sourceChainId, newEntries) != update.newAuthorityHash) {
            revert ReplacementHashMismatch();
        }
        _authenticate(
            sourceChainId, current.authorityHash, updateHash, recognized, evidence, newGraph, newEntries, childUpdates
        );

        // Validation precedes writes. Any revert rolls back the lock too.
        _store(newGraph, newEntries, update.newAuthorityHash);
        _selection = AuthoritySelection(updateHash, update.newAuthorityHash);
        emit AuthoritySelected(updateHash, update.newAuthorityHash);
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

    /// @dev Checks newGraph's structure and root record, proves every retained descendant
    ///      position in one flat pass over childUpdates, then the root's votes. An added Safe is
    ///      taken as newGraph names it, on the root's signers; it has no proven row, so it cannot
    ///      vote on this update. Signatures follow the graph because each descendant votes under
    ///      the position newGraph names for it.
    function _authenticate(
        uint256 sourceChainId,
        bytes32 currentAuthorityHash,
        bytes32 updateHash,
        RecognizedUpdate memory recognized,
        SafeTxEvidence calldata evidence,
        AuthorityGraph calldata newGraph,
        AuthorityEntry[] memory newEntries,
        ChildUpdate[] calldata childUpdates
    ) private view {
        SafeAuthorityRecord[] memory records = _requireCanonical(newGraph);
        AuthorityEntry[] storage stored = _graphs[currentAuthorityHash];
        ProvenTable memory table = ProvenTable(new ProvenPosition[](stored.length + childUpdates.length), 0);

        // The root votes under its stored record, never the new one (T6).
        SafeAuthorityRecord memory voters = record(stored[0].recordHash);
        if (recognized.kind == UpdateKind.OwnershipChange) {
            AuthorityMutations.applyMutations(voters, recognized.mutations, records[0]);
        } else if (stored[0].recordHash != newEntries[0].recordHash) {
            revert RootRecordMismatch();
        }
        for (uint256 i = 1; i < stored.length; ++i) {
            SafeAuthorityRecord memory seed = record(stored[i].recordHash);
            table.rows[i - 1] = ProvenPosition(seed.safe, stored[i].position, stored[i].recordHash, seed, true);
        }
        table.count = stored.length - 1;

        uint256 seeds = table.count;
        for (uint256 i; i < childUpdates.length; ++i) {
            _proveChildUpdate(sourceChainId, table, childUpdates[i], i);
        }
        for (uint256 i = 1; i < records.length; ++i) {
            address safe = records[i].safe;
            if (newEntries[i].position == bytes32(0)) revert UnprovenPosition(safe);
            uint256 at = _find(table, safe, newEntries[i].position);
            if (at == table.count) {
                // A retained Safe must be proven; one absent from the stored graph is added.
                if (_isSeeded(table, seeds, safe)) revert UnprovenPosition(safe);
                continue;
            }
            ProvenPosition memory row = table.rows[at];
            if (row.recordHash != newEntries[i].recordHash) revert DescendantRecordMismatch(safe);
            row.used = true;
        }
        // Each child update adds one row, so row seeds + i is childUpdates[i].
        for (uint256 i = seeds; i < table.count; ++i) {
            if (!table.rows[i].used) revert UnusedChildUpdate(i - seeds);
        }
        _verifyVotes(sourceChainId, records[0].safe, updateHash, evidence, voters, VoterPositions(table, newEntries));
    }

    /// @dev childUpdates[index] must extend a proven position of its Safe and add a position not
    ///      yet proven. Its voters are its predecessor record. An activation is never a child
    ///      update: a retained Safe's stored position is already at or after it.
    function _proveChildUpdate(
        uint256 sourceChainId,
        ProvenTable memory table,
        ChildUpdate calldata child,
        uint256 index
    ) private view {
        address safe = child.sourceSafe;
        RecognizedUpdate memory recognized = _recognizeUpdate(sourceChainId, safe, child.evidence);
        if (recognized.kind == UpdateKind.Activation) revert ActivationNotAccepted();
        AuthorityEntry[] memory entries = child.newGraphEntries;
        SafeAuthorityRecord memory newRecord = child.newRecord;
        bytes32 newRecordHash = AuthorityUpdateEncoding.recordHash(newRecord);
        if (newRecord.safe != safe || entries.length == 0 || entries[0].recordHash != newRecordHash) {
            revert ChildRecordMismatch(index);
        }
        if (AuthorityUpdateEncoding.graphHash(sourceChainId, entries) != recognized.update.newAuthorityHash) {
            revert ChildGraphHashMismatch(index);
        }

        uint256 at = _find(table, safe, recognized.update.previousUpdateHash);
        if (at == table.count) revert UnprovenPredecessor(index);
        ProvenPosition memory predecessor = table.rows[at];
        predecessor.used = true;
        SafeAuthorityRecord memory voters = predecessor.record;
        if (recognized.kind == UpdateKind.OwnershipChange) {
            _requireOwnerKinds(newRecord, index);
            AuthorityMutations.applyMutations(voters, recognized.mutations, newRecord);
        } else if (predecessor.recordHash != newRecordHash) {
            revert ChildRecordMismatch(index);
        }

        bytes32 position = SafeHashes.transactionHash(child.evidence.signedSafeTx.safeTx, safe, sourceChainId);
        if (_find(table, safe, position) != table.count) revert RepeatedChildUpdate(index);
        _verifyVotes(sourceChainId, safe, position, child.evidence, voters, VoterPositions(table, entries));
        table.rows[table.count++] = ProvenPosition(safe, position, newRecordHash, newRecord, false);
    }

    /// @notice The record a nested Safe voter counts under: its proven row at the position the
    ///         voting update's new graph names for it.
    /// @dev Marks the row used. A Safe owner the update removes has no named position, so it
    ///      cannot vote.
    function _voterRecord(VoterPositions memory positions, address safe)
        private
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

    /// @dev Full portable quorum of `voters` over `safeTxHash`, safe's SafeTx in evidence, as a
    ///      Safe 1.5.0 signature blob. Nested Safe voters, at any depth, count under
    ///      _voterRecord(positions, ...).
    function _verifyVotes(
        uint256 sourceChainId,
        address safe,
        bytes32 safeTxHash,
        SafeTxEvidence calldata evidence,
        SafeAuthorityRecord memory voters,
        VoterPositions memory positions
    ) private view {
        VoteContext memory votes = VoteContext(safe, voters, positions);
        bytes32 context;
        assembly ("memory-safe") {
            context := votes
        }
        SafeQuorum.verify(
            OwnerSource(context, sourceChainId, _openVoter, _isVoterOwner),
            safe,
            safeTxHash,
            evidence.signedSafeTx.signatures,
            evidence.nestedApprovals
        );
    }

    /// @dev `OwnerSource.open` over a vote context: the handle is the voter record's memory
    ///      pointer. The voting Safe counts under `voters` wherever a blob names it, so never
    ///      under its own new record (T6).
    function _openVoter(bytes32 context, address safe) private pure returns (bytes32 owners, uint256 threshold) {
        VoteContext memory votes;
        assembly ("memory-safe") {
            votes := context
        }
        SafeAuthorityRecord memory voterRecord = safe == votes.safe ? votes.voters : _voterRecord(votes.positions, safe);
        assembly ("memory-safe") {
            owners := voterRecord
        }
        threshold = voterRecord.threshold;
    }

    /// @dev `OwnerSource.isOwner` over a voter record. The kind must match exactly: an EOA-kind
    ///      owner never counts through a contract signature (Y10).
    function _isVoterOwner(bytes32 owners, address signer, uint8 kind) private pure returns (bool) {
        SafeAuthorityRecord memory voterRecord;
        assembly ("memory-safe") {
            voterRecord := owners
        }
        SafeOwner[] memory list = voterRecord.owners;
        for (uint256 i; i < list.length; ++i) {
            if (list[i].owner == signer) return list[i].kind == kind;
        }
        return false;
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

    /// @dev A child record that names new owners: the 16-owner cap and known kinds. applyMutations
    ///      checks the other group rules of an ownership change.
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

    /// @dev Recognize the signed source call of `sourceSafe`, the root or a child, so an activation
    ///      can be rejected by kind. No signature check.
    function _recognizeUpdate(uint256 sourceChainId, address sourceSafe, SafeTxEvidence calldata evidence)
        internal
        view
        virtual
        returns (RecognizedUpdate memory);

    /// @dev The receiver's source chain and owner Safe.
    function _authoritySource() internal view virtual returns (uint256 sourceChainId, address sourceSafe);

    /// @dev Concrete integration must share application-execution locking across providers.
    function _requireAuthorityContextIdle() internal view virtual;
}
