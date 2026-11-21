// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeAuthorityRecord, SafeOwner, OWNER_EOA, OWNER_SAFE} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {NestedOwnerManagerLib} from "src/messaging/signed/NestedOwnerManagerLib.sol";

/// @notice The canonical owner graph of a Safe and its nested Safes, and its commitment.
/// @dev Canonical order is depth first from the root: each Safe's owners in `getOwners()` order,
///      recursing into each nested Safe, one record per Safe at its first visit. A shared child
///      has one record. Live derivation and selected-graph validation share `walk`. Authority
///      updates also commit to each record's selected position through AuthorityUpdateEncoding.
library SafeAuthorityGraph {
    error EmptyAuthorityGraph();
    /// @dev An owner with code that does not answer `getOwners()` and `getThreshold()`.
    error NotASafe(address owner);
    error InvalidThreshold(address safe, uint256 threshold, uint256 ownerCount);
    /// @dev Zero, the list sentinel, the Safe itself, or listed twice.
    error InvalidOwner(address safe, address owner);
    error InvalidOwnerKind(address safe, address owner);
    error OwnerCycle(address safe);
    /// @dev A nested Safe owner has no record under its own address.
    error MissingAuthorityRecord(address safe);
    /// @dev The records are not in canonical order, or hold a duplicate or unreachable record.
    error NonCanonicalAuthorityGraph();

    /// @notice Hash the encoded ordered Safe authority records.
    function hash(SafeAuthorityRecord[] memory records) internal pure returns (bytes32) {
        return keccak256(abi.encode(records));
    }

    /// @dev Empty code and exact EIP-7702 delegation indicators count as EOAs; other owners must answer
    ///      as Safes, but their implementation is not attested.
    function derive(address root) internal view returns (SafeAuthorityRecord[] memory) {
        return walk(root, bytes32(0), _loadLive);
    }

    /// @notice Validate the supplied graph's owner groups, reachability, kinds and canonical
    ///         record order.
    /// @dev Receivers reject ambiguous graph encodings before storing them as authority.
    function requireCanonical(SafeAuthorityRecord[] memory records) internal view {
        if (records.length == 0) revert EmptyAuthorityGraph();
        Supplied memory supplied = Supplied(records, _newIndex(records.length));
        for (uint256 i; i < records.length; ++i) {
            _insert(supplied.slots, records, i);
        }
        bytes32 context;
        assembly ("memory-safe") {
            context := supplied
        }
        SafeAuthorityRecord[] memory walked = walk(records[0].safe, context, _loadRecord);

        // `walked` holds each reachable Safe once, taking the first record declared for it, so
        // equal length and order leave no duplicate, conflicting or unreachable record.
        if (walked.length != records.length) revert NonCanonicalAuthorityGraph();
        for (uint256 i; i < walked.length; ++i) {
            if (walked[i].safe != records[i].safe) revert NonCanonicalAuthorityGraph();
        }
        // An owner marked as an EOA must not also have a record.
        for (uint256 i; i < records.length; ++i) {
            SafeOwner[] memory owners = records[i].owners;
            for (uint256 j; j < owners.length; ++j) {
                if (
                    owners[j].kind == OWNER_EOA && supplied.slots[_probe(supplied.slots, records, owners[j].owner)] != 0
                ) {
                    revert InvalidOwnerKind(records[i].safe, owners[j].owner);
                }
            }
        }
    }

    /// @dev `slots` indexes `records` by Safe address, first declaration winning.
    struct Supplied {
        SafeAuthorityRecord[] records;
        uint256[] slots;
    }

    struct TraversalState {
        SafeAuthorityRecord[] records;
        // Whether the Safe at the same index is on the current path from the root.
        bool[] open;
        // Address index over `records[0..count)`.
        uint256[] slots;
        uint256 count;
    }

    /// @notice Traverse from a root using the supplied owner loader and return each reachable
    ///         Safe once.
    /// @dev Using one depth-first traversal for live, supplied and stored records keeps their
    ///      canonical ordering consistent while validating each group.
    function walk(
        address root,
        bytes32 context,
        function(bytes32, address) view returns (SafeOwner[] memory, uint256) load
    ) internal view returns (SafeAuthorityRecord[] memory records) {
        TraversalState memory traversal = TraversalState(new SafeAuthorityRecord[](4), new bool[](4), _newIndex(4), 0);
        _visit(traversal, root, context, load);
        records = traversal.records;
        uint256 count = traversal.count;
        assembly ("memory-safe") {
            mstore(records, count)
        }
    }

    /// @dev Tracking the active path rejects cycles while a child shared by several parents keeps one
    ///      record.
    function _visit(
        TraversalState memory traversal,
        address safe,
        bytes32 context,
        function(bytes32, address) view returns (SafeOwner[] memory, uint256) load
    ) private view {
        uint256 index = traversal.slots[_probe(traversal.slots, traversal.records, safe)];
        if (index != 0) {
            if (traversal.open[index - 1]) revert OwnerCycle(safe);
            return;
        }

        (SafeOwner[] memory owners, uint256 threshold) = load(context, safe);
        _requireGroup(safe, owners, threshold);

        index = traversal.count;
        if (index == traversal.records.length) _grow(traversal);
        traversal.records[index] = SafeAuthorityRecord(safe, threshold, owners);
        _insert(traversal.slots, traversal.records, index);
        traversal.open[index] = true;
        traversal.count = index + 1;

        for (uint256 i; i < owners.length; ++i) {
            if (owners[i].kind == OWNER_SAFE) _visit(traversal, owners[i].owner, context, load);
        }
        traversal.open[index] = false;
    }

    function _requireGroup(address safe, SafeOwner[] memory owners, uint256 threshold) private pure {
        if (threshold == 0 || threshold > owners.length) revert InvalidThreshold(safe, threshold, owners.length);
        for (uint256 i; i < owners.length; ++i) {
            address owner = owners[i].owner;
            if (owner == address(0) || owner == NestedOwnerManagerLib.SENTINEL || owner == safe) {
                revert InvalidOwner(safe, owner);
            }
            if (owners[i].kind > OWNER_SAFE) revert InvalidOwnerKind(safe, owner);
            for (uint256 j; j < i; ++j) {
                if (owners[j].owner == owner) revert InvalidOwner(safe, owner);
            }
        }
    }

    /// @notice An open-addressing table of record positions, empty, sized to at least twice
    ///         `capacity` so a probe always reaches an empty slot.
    /// @dev A slot holds the record's index plus one, so zero is empty.
    function _newIndex(uint256 capacity) private pure returns (uint256[] memory) {
        uint256 size = 8;
        while (size < capacity * 2) size *= 2;
        // forge-lint: disable-next-line(calls-loop) a memory allocation, not a call
        return new uint256[](size);
    }

    /// @notice The slot holding `safe`'s record, or the empty slot where it belongs.
    function _probe(uint256[] memory slots, SafeAuthorityRecord[] memory records, address safe)
        private
        pure
        returns (uint256 pos)
    {
        uint256 mask = slots.length - 1;
        assembly ("memory-safe") {
            mstore(0, and(safe, 0xffffffffffffffffffffffffffffffffffffffff))
            pos := and(keccak256(0, 32), mask)
        }
        for (;;) {
            uint256 held = slots[pos];
            if (held == 0 || records[held - 1].safe == safe) return pos;
            pos = (pos + 1) & mask;
        }
    }

    /// @dev Records `records[index]` unless an earlier record has the same Safe.
    function _insert(uint256[] memory slots, SafeAuthorityRecord[] memory records, uint256 index) private pure {
        uint256 pos = _probe(slots, records, records[index].safe);
        if (slots[pos] == 0) slots[pos] = index + 1;
    }

    /// @dev Doubles the traversal buffers, copies the visited records and path flags, and rebuilds the
    ///      index.
    function _grow(TraversalState memory traversal) private pure {
        uint256 capacity = traversal.records.length * 2;
        // forge-lint: disable-next-line(calls-loop) a memory allocation, not a call
        SafeAuthorityRecord[] memory records = new SafeAuthorityRecord[](capacity);
        // forge-lint: disable-next-line(calls-loop) a memory allocation, not a call
        bool[] memory open = new bool[](capacity);
        for (uint256 i; i < traversal.count; ++i) {
            records[i] = traversal.records[i];
            open[i] = traversal.open[i];
        }
        traversal.records = records;
        traversal.open = open;
        traversal.slots = _newIndex(capacity);
        for (uint256 i; i < traversal.count; ++i) {
            _insert(traversal.slots, records, i);
        }
    }

    /* ================================== loaders ================================= */

    /// @dev `context` is a `Supplied` memory pointer.
    function _loadRecord(bytes32 context, address safe) private pure returns (SafeOwner[] memory, uint256) {
        Supplied memory supplied;
        assembly ("memory-safe") {
            supplied := context
        }
        uint256 held = supplied.slots[_probe(supplied.slots, supplied.records, safe)];
        if (held == 0) revert MissingAuthorityRecord(safe);
        return (supplied.records[held - 1].owners, supplied.records[held - 1].threshold);
    }

    /// @dev Owner kinds are captured because the receiver verifies EOAs and nested Safes differently.
    function _loadLive(bytes32, address safe) private view returns (SafeOwner[] memory owners, uint256 threshold) {
        // getOwners() and getThreshold()
        bytes memory reply = _ask(safe, 0xa0e67e2b, 64);
        address[] memory list = abi.decode(reply, (address[]));
        threshold = abi.decode(_ask(safe, 0xe75235b8, 32), (uint256));

        owners = new SafeOwner[](list.length);
        for (uint256 i; i < list.length; ++i) {
            owners[i] = SafeOwner(list[i], _isEoa(list[i]) ? OWNER_EOA : OWNER_SAFE);
        }
    }

    function _ask(address safe, bytes4 selector, uint256 minimum) private view returns (bytes memory reply) {
        bool ok;
        (ok, reply) = safe.staticcall(abi.encodeWithSelector(selector));
        if (!ok || reply.length < minimum) revert NotASafe(safe);
    }

    /// @dev A delegated EOA still signs with its key; treating it as a nested Safe would require Safe
    ///      ownership methods it lacks.
    function _isEoa(address owner) private view returns (bool) {
        uint256 size = owner.code.length;
        if (size == 0) return true;
        if (size != 23) return false;
        bytes32 word;
        assembly ("memory-safe") {
            mstore(0, 0)
            extcodecopy(owner, 0, 0, 3)
            word := mload(0)
        }
        // forge-lint: disable-next-line(unsafe-typecast) the first three bytes of the code just copied
        return bytes3(word) == 0xef0100;
    }
}
