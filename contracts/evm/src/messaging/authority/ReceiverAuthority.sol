// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {AuthoritySelection, AuthorityUpdate} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {Call} from "src/messaging/Call.sol";
import {SafeAuthorityGraph} from "src/messaging/signed/SafeAuthorityGraph.sol";
import {OwnerSource, SafeQuorum} from "src/messaging/signed/SafeQuorum.sol";
import {OWNER_SAFE, SafeAuthorityRecord, SafeOwner} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {SafeTxEvidence, SignedBootstrap} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {AuthorityEntry, AuthorityGraph, AuthorityNode, MAX_SAFE_OWNERS} from "./AuthorityGraph.sol";
import {AuthorityMutations} from "./AuthorityMutations.sol";
import {ChildUpdate} from "./ChildUpdate.sol";
import {AuthorityUpdateEncoding} from "./AuthorityUpdateEncoding.sol";
import {AuthorityRecognition} from "./AuthorityRecognition.sol";

/// @notice A signed receiver's #109 authority: its selection, graph and records, and the checks
///         that move them. External, so linked and called by DELEGATECALL against the receiver's
///         storage, which keeps the verifier out of each receiver's EIP-170 budget.
/// @dev Owns graph authentication: canonical structure, each update kind's root record, the
///      flat child-update pass and every update's votes. Receiver submission recognizes pinned
///      source calls; the source guard can supply its own recognized calls. The first selection is seeded from the receiver's
///      bootstrap; activations are never accepted.
library ReceiverAuthority {
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

    /// @dev The recognized root update and childUpdates[i]'s recognized call at children[i].
    struct Recognized {
        RecognizedUpdate root;
        RecognizedUpdate[] children;
    }

    struct UpdateRequest {
        uint256 sourceChainId;
        address sourceSafe;
        SafeTxEvidence evidence;
        AuthorityGraph newGraph;
        ChildUpdate[] childUpdates;
        Recognized recognized;
    }

    struct SubmissionRequest {
        uint256 sourceChainId;
        AuthorityRecognition.Context context;
        SafeTxEvidence evidence;
        AuthorityGraph newGraph;
        ChildUpdate[] childUpdates;
    }

    struct State {
        AuthoritySelection selection;
        // Content-addressed: a record shared by several graphs or kept across updates is written once.
        mapping(bytes32 => bytes) records;
        mapping(bytes32 => AuthorityEntry[]) graphs;
        // Only the current accepted submission authenticates a provider retry. Bootstrap sets none.
        bytes32 lastSubmissionHash;
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

    error UnseededAuthority();
    error AlreadySeeded();
    error ActivationHashMismatch();
    error ActivationRootMismatch();
    error ActivationKindRequired();
    error ActivationNotAccepted();
    error ChildRecognitionMismatch();
    error WrongRoot();
    error RootPositionNotZero();
    error ZeroCommitment();
    error PreviousUpdateMismatch();
    error ReplacementHashMismatch();
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
    error BootstrapGuardMismatch();
    error RootIsNotOwner(address owner, address root);

    function encodedGraphHash(uint256 sourceChainId, bytes memory encoded) external pure returns (bytes32) {
        return AuthorityUpdateEncoding.graphHash(sourceChainId, abi.decode(encoded, (AuthorityGraph)));
    }

    /// @notice Seed a provider-authenticated bootstrap under the implementation's guard pin.
    function bootstrap(State storage $, uint256 sourceChainId, address sourceSafe, address guard, bytes memory body)
        external
        returns (AuthoritySelection memory selected, bytes memory setupCalls)
    {
        SignedBootstrap memory initial = abi.decode(body, (SignedBootstrap));
        if (initial.guard != guard) revert BootstrapGuardMismatch();
        AuthorityGraph memory authority = abi.decode(initial.authority, (AuthorityGraph));
        if (authority.nodes.length != 0 && authority.nodes[0].record.safe != sourceSafe) {
            revert RootIsNotOwner(sourceSafe, authority.nodes[0].record.safe);
        }
        seed($, sourceChainId, sourceSafe, initial.updateHead, authority);
        return ($.selection, initial.setupCalls);
    }

    function graph(State storage $, bytes32 authorityHash) public view returns (AuthorityGraph memory authority) {
        AuthorityEntry[] storage stored = $.graphs[authorityHash];
        if (stored.length == 0) revert GraphNotCached();
        authority.nodes = new AuthorityNode[](stored.length);
        for (uint256 i; i < stored.length; ++i) {
            authority.nodes[i] = AuthorityNode(record($, stored[i].recordHash), stored[i].position);
        }
    }

    function record(State storage $, bytes32 recordHash) public view returns (SafeAuthorityRecord memory) {
        bytes storage encoded = $.records[recordHash];
        if (encoded.length == 0) revert RecordNotCached();
        return abi.decode(encoded, (SafeAuthorityRecord));
    }

    function selectedRecords(State storage $) external view returns (SafeAuthorityRecord[] memory records) {
        AuthorityEntry[] storage entries = $.graphs[$.selection.authorityHash];
        records = new SafeAuthorityRecord[](entries.length);
        for (uint256 i; i < entries.length; ++i) {
            records[i] = record($, entries[i].recordHash);
        }
    }

    /// @notice Verify application evidence under the selected graph without changing its head.
    function verify(State storage $, uint256 sourceChainId, address sourceSafe, SafeTxEvidence memory evidence)
        external
        view
        returns (bytes32 safeTxHash)
    {
        (SafeAuthorityRecord memory voters, VoterPositions memory positions) = _storedVoters($, 0);
        safeTxHash = SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, sourceSafe, sourceChainId);
        _verifyVotes(sourceChainId, safeTxHash, evidence, VoteContext(sourceSafe, voters, positions));
    }

    function _storedVoters(State storage $, uint256 extra)
        private
        view
        returns (SafeAuthorityRecord memory voters, VoterPositions memory positions)
    {
        if ($.selection.authorityHash == bytes32(0)) revert UnseededAuthority();
        AuthorityEntry[] memory stored = $.graphs[$.selection.authorityHash];
        ProvenTable memory table = ProvenTable(new ProvenPosition[](stored.length + extra), stored.length - 1);
        voters = record($, stored[0].recordHash);
        for (uint256 i = 1; i < stored.length; ++i) {
            SafeAuthorityRecord memory kept = record($, stored[i].recordHash);
            table.rows[i - 1] = ProvenPosition(kept.safe, stored[i].position, stored[i].recordHash, kept, true);
        }
        positions = VoterPositions(table, stored);
    }

    /// @notice Store the head and selected graph a bootstrap carried, once.
    /// @dev Taken on the provider's authentication of the bootstrap (#148): signatures cannot
    ///      prove a carried graph. Shape checks still apply.
    function seed(
        State storage $,
        uint256 sourceChainId,
        address sourceSafe,
        bytes32 updateHead,
        AuthorityGraph memory initial
    ) public returns (bytes32 authorityHash) {
        if ($.selection.authorityHash != bytes32(0)) revert AlreadySeeded();
        if (updateHead == bytes32(0)) revert ZeroCommitment();
        _requireRoot(sourceSafe, initial);
        _requireCanonical(initial);
        AuthorityEntry[] memory entries = AuthorityUpdateEncoding.entries(initial);
        for (uint256 i = 1; i < entries.length; ++i) {
            if (entries[i].position == bytes32(0)) revert UnprovenPosition(initial.nodes[i].record.safe);
        }
        authorityHash = AuthorityUpdateEncoding.graphHash(sourceChainId, entries);
        _store($, initial, entries, authorityHash);
        $.selection = AuthoritySelection(updateHead, authorityHash);
    }

    /// @notice A source Safe's first selection, from its signed activation.
    /// @dev Source guard only: receivers start from `seed` and never accept an activation. The
    ///      initial graph's root record must equal `live`, and the portable votes are checked under
    ///      `live` with each descendant counted at the position the graph names. The caller has
    ///      checked that every named position is an executed head with that record.
    /// @return updateHash The activation's SafeTx hash, the Safe's first head.
    function activate(
        State storage $,
        uint256 sourceChainId,
        address sourceSafe,
        SafeTxEvidence memory evidence,
        AuthorityGraph memory initial,
        SafeAuthorityRecord memory live,
        RecognizedUpdate memory recognized
    ) external returns (bytes32 updateHash) {
        if ($.selection.authorityHash != bytes32(0)) revert AlreadySeeded();
        if (recognized.kind != UpdateKind.Activation) revert ActivationKindRequired();
        updateHash = SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, sourceSafe, sourceChainId);
        if (updateHash == bytes32(0)) revert ZeroCommitment();
        _requireRoot(sourceSafe, initial);
        SafeAuthorityRecord[] memory records = _requireCanonical(initial);
        AuthorityEntry[] memory entries = AuthorityUpdateEncoding.entries(initial);
        if (
            recognized.update.newAuthorityHash == bytes32(0)
                || AuthorityUpdateEncoding.graphHash(sourceChainId, entries) != recognized.update.newAuthorityHash
        ) revert ActivationHashMismatch();
        if (entries[0].recordHash != AuthorityUpdateEncoding.recordHash(live)) revert ActivationRootMismatch();

        ProvenTable memory table = ProvenTable(new ProvenPosition[](records.length), 0);
        for (uint256 i = 1; i < records.length; ++i) {
            if (entries[i].position == bytes32(0)) revert UnprovenPosition(records[i].safe);
            table.rows[table.count++] =
                ProvenPosition(records[i].safe, entries[i].position, entries[i].recordHash, records[i], false);
        }
        _verifyVotes(sourceChainId, updateHash, evidence, VoteContext(sourceSafe, live, VoterPositions(table, entries)));
        _store($, initial, entries, recognized.update.newAuthorityHash);
        $.selection = AuthoritySelection(updateHash, recognized.update.newAuthorityHash);
    }

    /// @notice Verify and apply the next signed update: a successor of the stored head.
    /// @return updateHash The new head, the update's SafeTx hash.
    function applyUpdate(State storage $, UpdateRequest memory request) external returns (bytes32 updateHash) {
        return _applyUpdate(
            $,
            request.sourceChainId,
            request.sourceSafe,
            request.evidence,
            request.newGraph,
            request.childUpdates,
            request.recognized
        );
    }

    function submit(State storage $, SubmissionRequest memory request) external returns (bytes32 updateHash) {
        Recognized memory recognized =
            AuthorityRecognition.recognizeUpdates(request.context, request.evidence, request.childUpdates);
        updateHash = _applyUpdate(
            $,
            request.sourceChainId,
            request.context.safe,
            request.evidence,
            request.newGraph,
            request.childUpdates,
            recognized
        );
    }

    function _applyUpdate(
        State storage $,
        uint256 sourceChainId,
        address sourceSafe,
        SafeTxEvidence memory evidence,
        AuthorityGraph memory newGraph,
        ChildUpdate[] memory childUpdates,
        Recognized memory recognized
    ) private returns (bytes32 updateHash) {
        _requireRoot(sourceSafe, newGraph);
        updateHash = SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, sourceSafe, sourceChainId);
        if (updateHash == bytes32(0)) revert ZeroCommitment();
        if ($.selection.authorityHash == bytes32(0)) revert UnseededAuthority();
        if (recognized.root.kind == UpdateKind.Activation) revert ActivationNotAccepted();
        if (recognized.children.length != childUpdates.length) revert ChildRecognitionMismatch();
        AuthorityUpdate memory update = recognized.root.update;
        // Also the replay check: each head commits to its predecessor, so heads never repeat
        // and an accepted update cannot match the stored head again.
        if (update.previousUpdateHash != $.selection.updateHead) revert PreviousUpdateMismatch();
        if (update.newAuthorityHash == bytes32(0)) revert ZeroCommitment();
        AuthorityEntry[] memory newEntries = AuthorityUpdateEncoding.entries(newGraph);
        if (AuthorityUpdateEncoding.graphHash(sourceChainId, newEntries) != update.newAuthorityHash) {
            revert ReplacementHashMismatch();
        }
        _authenticate($, sourceChainId, updateHash, recognized, evidence, newGraph, newEntries, childUpdates);

        // Validation precedes writes.
        _store($, newGraph, newEntries, update.newAuthorityHash);
        $.selection = AuthoritySelection(updateHash, update.newAuthorityHash);
    }

    function _requireRoot(address sourceSafe, AuthorityGraph memory authority) private pure {
        if (sourceSafe == address(0) || authority.nodes.length == 0 || authority.nodes[0].record.safe != sourceSafe) {
            revert WrongRoot();
        }
        if (authority.nodes[0].position != bytes32(0)) revert RootPositionNotZero();
    }

    function _store(
        State storage $,
        AuthorityGraph memory authority,
        AuthorityEntry[] memory graphEntries,
        bytes32 authorityHash
    ) private {
        for (uint256 i; i < graphEntries.length; ++i) {
            bytes storage stored = $.records[graphEntries[i].recordHash];
            // forge-lint: disable-next-line(costly-loop) one write per record not stored yet
            if (stored.length == 0) $.records[graphEntries[i].recordHash] = abi.encode(authority.nodes[i].record);
        }
        // A graph returning to an earlier hash is already stored under it.
        AuthorityEntry[] storage graphSlot = $.graphs[authorityHash];
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
        State storage $,
        uint256 sourceChainId,
        bytes32 updateHash,
        Recognized memory recognized,
        SafeTxEvidence memory evidence,
        AuthorityGraph memory newGraph,
        AuthorityEntry[] memory newEntries,
        ChildUpdate[] memory childUpdates
    ) private view {
        SafeAuthorityRecord[] memory records = _requireCanonical(newGraph);
        AuthorityEntry[] storage stored = $.graphs[$.selection.authorityHash];
        // The root votes under its stored record, never the new one (T6).
        (SafeAuthorityRecord memory voters, VoterPositions memory positions) = _storedVoters($, childUpdates.length);
        ProvenTable memory table = positions.table;
        if (recognized.root.kind == UpdateKind.OwnershipChange) {
            AuthorityMutations.applyMutations(voters, recognized.root.mutations, records[0]);
        } else if (stored[0].recordHash != newEntries[0].recordHash) {
            revert RootRecordMismatch();
        }
        uint256 seeds = table.count;
        for (uint256 i; i < childUpdates.length; ++i) {
            _proveChildUpdate(sourceChainId, table, childUpdates[i], recognized.children[i], i);
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
        _verifyVotes(
            sourceChainId, updateHash, evidence, VoteContext(records[0].safe, voters, VoterPositions(table, newEntries))
        );
    }

    /// @dev childUpdates[index] must extend a proven position of its Safe and add a position not
    ///      yet proven. Its voters are its predecessor record. An activation is never a child
    ///      update: a retained Safe's stored position is already at or after it.
    function _proveChildUpdate(
        uint256 sourceChainId,
        ProvenTable memory table,
        ChildUpdate memory child,
        RecognizedUpdate memory recognized,
        uint256 index
    ) private view {
        if (recognized.kind == UpdateKind.Activation) revert ActivationNotAccepted();
        VoteContext memory votes;
        votes.safe = child.sourceSafe;
        votes.positions = VoterPositions(table, child.newGraphEntries);
        bytes32 newRecordHash = AuthorityUpdateEncoding.recordHash(child.newRecord);
        if (
            child.newRecord.safe != votes.safe || child.newGraphEntries.length == 0
                || child.newGraphEntries[0].recordHash != newRecordHash
        ) {
            revert ChildRecordMismatch(index);
        }
        if (
            AuthorityUpdateEncoding.graphHash(sourceChainId, child.newGraphEntries)
                != recognized.update.newAuthorityHash
        ) {
            revert ChildGraphHashMismatch(index);
        }

        {
            uint256 at = _find(table, votes.safe, recognized.update.previousUpdateHash);
            if (at == table.count) revert UnprovenPredecessor(index);
            ProvenPosition memory predecessor = table.rows[at];
            predecessor.used = true;
            votes.voters = predecessor.record;
            if (recognized.kind == UpdateKind.OwnershipChange) {
                _requireOwnerKinds(child.newRecord, index);
                AuthorityMutations.applyMutations(votes.voters, recognized.mutations, child.newRecord);
            } else if (predecessor.recordHash != newRecordHash) {
                revert ChildRecordMismatch(index);
            }
        }

        bytes32 position = SafeHashes.transactionHash(child.evidence.signedSafeTx.safeTx, votes.safe, sourceChainId);
        if (_find(table, votes.safe, position) != table.count) revert RepeatedChildUpdate(index);
        _verifyVotes(sourceChainId, position, child.evidence, votes);
        table.rows[table.count++] = ProvenPosition(votes.safe, position, newRecordHash, child.newRecord, false);
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
        bytes32 safeTxHash,
        SafeTxEvidence memory evidence,
        VoteContext memory votes
    ) private view {
        bytes32 context;
        assembly ("memory-safe") {
            context := votes
        }
        SafeQuorum.verify(
            OwnerSource(context, sourceChainId, _openVoter, _isVoterOwner),
            votes.safe,
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
    function _requireCanonical(AuthorityGraph memory authority)
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
}
