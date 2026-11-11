// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeAuthorityRecord, SafeOwner, OWNER_EOA, OWNER_SAFE} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {NestedOwnerManagerLib} from "src/messaging/signed/NestedOwnerManagerLib.sol";

/// @notice The canonical owner graph of a Safe and its nested Safes, and its commitment.
/// @dev Canonical order is depth first from the root: each Safe's owners in `getOwners()` order,
///      recursing into each nested Safe, one record per Safe at its first visit. A shared child
///      has one record. `hash` over that order is the graph field of a signed conduit's salt, so the
///      transmitter and the receiver must produce the same order: both go through `walk`.
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

    function hash(SafeAuthorityRecord[] memory records) internal pure returns (bytes32) {
        return keccak256(abi.encode(records));
    }

    /// @notice The canonical records of `root`, read from each Safe's live owners and threshold.
    /// @dev An owner with no code, or with an EIP-7702 delegation indicator, is an EOA. Any other
    ///      owner must answer as a Safe. Its implementation is not checked.
    function derive(address root) internal view returns (SafeAuthorityRecord[] memory) {
        return walk(root, bytes32(0), _loadLive);
    }

    /// @notice Reverts unless `records` is what `derive` could have produced for its first record.
    function requireCanonical(SafeAuthorityRecord[] memory records) internal view {
        if (records.length == 0) revert EmptyAuthorityGraph();
        bytes32 context;
        assembly ("memory-safe") {
            context := records
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
                    owners[j].kind == OWNER_EOA
                        && _indexOf(records, records.length, owners[j].owner) != type(uint256).max
                ) {
                    revert InvalidOwnerKind(records[i].safe, owners[j].owner);
                }
            }
        }
    }

    struct TraversalState {
        SafeAuthorityRecord[] records;
        // Whether the Safe at the same index is on the current path from the root.
        bool[] open;
        uint256 count;
    }

    /// @notice The canonical records reachable from `root`, taking each Safe's owners and
    ///         threshold from `load(context, safe)`. Validates every group it visits.
    function walk(
        address root,
        bytes32 context,
        function(bytes32, address) view returns (SafeOwner[] memory, uint256) load
    ) internal view returns (SafeAuthorityRecord[] memory records) {
        TraversalState memory traversal = TraversalState(new SafeAuthorityRecord[](4), new bool[](4), 0);
        _visit(traversal, root, context, load);
        records = traversal.records;
        uint256 count = traversal.count;
        assembly ("memory-safe") {
            mstore(records, count)
        }
    }

    function _visit(
        TraversalState memory traversal,
        address safe,
        bytes32 context,
        function(bytes32, address) view returns (SafeOwner[] memory, uint256) load
    ) private view {
        uint256 index = _indexOf(traversal.records, traversal.count, safe);
        if (index != type(uint256).max) {
            if (traversal.open[index]) revert OwnerCycle(safe);
            return;
        }

        (SafeOwner[] memory owners, uint256 threshold) = load(context, safe);
        _checkGroup(safe, owners, threshold);

        index = traversal.count;
        if (index == traversal.records.length) _grow(traversal);
        traversal.records[index] = SafeAuthorityRecord(safe, threshold, owners);
        traversal.open[index] = true;
        traversal.count = index + 1;

        for (uint256 i; i < owners.length; ++i) {
            if (owners[i].kind == OWNER_SAFE) _visit(traversal, owners[i].owner, context, load);
        }
        traversal.open[index] = false;
    }

    function _checkGroup(address safe, SafeOwner[] memory owners, uint256 threshold) private pure {
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

    function _indexOf(SafeAuthorityRecord[] memory records, uint256 count, address safe)
        private
        pure
        returns (uint256)
    {
        for (uint256 i; i < count; ++i) {
            if (records[i].safe == safe) return i;
        }
        return type(uint256).max;
    }

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
    }

    /* ================================== loaders ================================= */

    /// @dev `context` is a memory pointer to the `SafeAuthorityRecord[]` being checked.
    function _loadRecord(bytes32 context, address safe) private pure returns (SafeOwner[] memory, uint256) {
        SafeAuthorityRecord[] memory records;
        assembly ("memory-safe") {
            records := context
        }
        uint256 index = _indexOf(records, records.length, safe);
        if (index == type(uint256).max) revert MissingAuthorityRecord(safe);
        return (records[index].owners, records[index].threshold);
    }

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

    /// @dev Empty code, or exactly the 23-byte EIP-7702 indicator `0xef0100 || address`.
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
