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
///      source calls; the source guard supplies recognized calls. A receiver starts from its
///      bootstrap and rejects submitted activations; the source guard uses verifyActivation.
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
    error CurrentAuthorityMismatch();
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
        SafeAuthorityRecord[] memory records = new SafeAuthorityRecord[](stored.length);
        for (uint256 i; i < stored.length; ++i) {
            records[i] = record($, stored[i].recordHash);
        }
        return _voters(records, stored, extra);
    }

    function _voters(SafeAuthorityRecord[] memory records, AuthorityEntry[] memory entries, uint256 extra)
        private
        pure
        returns (SafeAuthorityRecord memory voters, VoterPositions memory positions)
    {
        ProvenTable memory table = ProvenTable(new ProvenPosition[](records.length + extra), records.length - 1);
        for (uint256 i = 1; i < records.length; ++i) {
            table.rows[i - 1] =
                ProvenPosition(records[i].safe, entries[i].position, entries[i].recordHash, records[i], true);
        }
        return (records[0], VoterPositions(table, entries));
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
    function verifyActivation(
        uint256 sourceChainId,
        address sourceSafe,
        SafeTxEvidence memory evidence,
        AuthorityGraph memory initial,
        SafeAuthorityRecord memory live,
        RecognizedUpdate memory recognized
    ) external view returns (bytes32 updateHash) {
        if (recognized.kind != UpdateKind.Activation) {
            revert ActivationKindRequired();
        }
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
    }

    /// @notice Verify a source update using the exact graph committed by its current selection.
    /// @dev The guard persists only the returned selection hashes; receivers use the same
    ///      transition check against their stored full graph.
    function verifyUpdate(
        AuthoritySelection memory current,
        AuthorityGraph memory currentGraph,
        UpdateRequest memory request
    ) external view returns (bytes32 updateHash) {
        AuthorityEntry[] memory entries = AuthorityUpdateEncoding.entries(currentGraph);
        if (AuthorityUpdateEncoding.graphHash(request.sourceChainId, entries) != current.authorityHash) {
            revert CurrentAuthorityMismatch();
        }
        _requireRoot(request.sourceSafe, currentGraph);
        (SafeAuthorityRecord memory voters, VoterPositions memory positions) =
            _voters(_requireCanonical(currentGraph), entries, request.childUpdates.length);
        (updateHash,) = _verifyUpdate(current, request, VoteContext(request.sourceSafe, voters, positions));
    }

    function submit(State storage $, SubmissionRequest memory request) external returns (bytes32 updateHash) {
        Recognized memory recognized =
            AuthorityRecognition.recognizeUpdates(request.context, request.evidence, request.childUpdates);
        UpdateRequest memory update = UpdateRequest(
            request.sourceChainId,
            request.context.safe,
            request.evidence,
            request.newGraph,
            request.childUpdates,
            recognized
        );
        (SafeAuthorityRecord memory voters, VoterPositions memory positions) =
            _storedVoters($, request.childUpdates.length);
        AuthorityEntry[] memory entries;
        (updateHash, entries) = _verifyUpdate($.selection, update, VoteContext(request.context.safe, voters, positions));
        _store($, request.newGraph, entries, recognized.root.update.newAuthorityHash);
        $.selection = AuthoritySelection(updateHash, recognized.root.update.newAuthorityHash);
    }

    function _verifyUpdate(AuthoritySelection memory current, UpdateRequest memory request, VoteContext memory previous)
        private
        view
        returns (bytes32 updateHash, AuthorityEntry[] memory newEntries)
    {
        _requireRoot(request.sourceSafe, request.newGraph);
        updateHash =
            SafeHashes.transactionHash(request.evidence.signedSafeTx.safeTx, request.sourceSafe, request.sourceChainId);
        if (updateHash == bytes32(0)) revert ZeroCommitment();
        if (current.authorityHash == bytes32(0)) revert UnseededAuthority();
        if (request.recognized.root.kind == UpdateKind.Activation) revert ActivationNotAccepted();
        if (request.recognized.children.length != request.childUpdates.length) revert ChildRecognitionMismatch();
        AuthorityUpdate memory update = request.recognized.root.update;
        // Also the replay check: each head commits to its predecessor, so heads never repeat
        // and an accepted update cannot match the stored head again.
        if (update.previousUpdateHash != current.updateHead) revert PreviousUpdateMismatch();
        if (update.newAuthorityHash == bytes32(0)) revert ZeroCommitment();
        newEntries = AuthorityUpdateEncoding.entries(request.newGraph);
        if (AuthorityUpdateEncoding.graphHash(request.sourceChainId, newEntries) != update.newAuthorityHash) {
            revert ReplacementHashMismatch();
        }
        _authenticate(request, updateHash, newEntries, previous);
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
        UpdateRequest memory request,
        bytes32 updateHash,
        AuthorityEntry[] memory newEntries,
        VoteContext memory previous
    ) private view {
        SafeAuthorityRecord[] memory records = _requireCanonical(request.newGraph);
        // The root votes under its stored record, never the new one (T6).
        ProvenTable memory table = previous.positions.table;
        if (request.recognized.root.kind == UpdateKind.OwnershipChange) {
            AuthorityMutations.applyMutations(previous.voters, request.recognized.root.mutations, records[0]);
        } else if (previous.positions.entries[0].recordHash != newEntries[0].recordHash) {
            revert RootRecordMismatch();
        }
        uint256 seeds = table.count;
        for (uint256 i; i < request.childUpdates.length; ++i) {
            _proveChildUpdate(request.sourceChainId, table, request.childUpdates[i], request.recognized.children[i], i);
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
            request.sourceChainId,
            updateHash,
            request.evidence,
            VoteContext(records[0].safe, previous.voters, VoterPositions(table, newEntries))
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
