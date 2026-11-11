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

    /// @notice Hash the encoded ordered Safe authority records.
    /// @dev Signed conduit addresses commit to this hash, so a different owner graph must
    ///      derive a different signed address.
    function hash(SafeAuthorityRecord[] memory records) internal pure returns (bytes32) {
        return keccak256(abi.encode(records));
    }

    /// @notice Read the root Safe and its nested Safes into canonical authority records.
    /// @dev This captures the live source ownership used to derive a signed conduit. Empty code
    ///      and exact EIP-7702 delegation indicators count as EOAs; other owners must answer as
    ///      Safes, but their implementation is not attested.
    function derive(address root) internal view returns (SafeAuthorityRecord[] memory) {
        return walk(root, bytes32(0), _loadLive);
    }

    /// @notice Validate the supplied graph's owner groups, reachability, kinds and canonical
    ///         record order.
    /// @dev Receivers must reject ambiguous or substituted graph encodings before trusting
    ///      their authority or matching their address commitment.
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

    /// @notice Traverse from a root using the supplied owner loader and return each reachable
    ///         Safe once.
    /// @dev Using one depth-first traversal for live, supplied and stored records keeps their
    ///      canonical ordering consistent while validating each group.
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

    /// @notice Visit a Safe, validate its owner group and recursively visit its nested Safe
    ///         owners.
    /// @dev Tracking the active path rejects cycles while allowing a child shared by several
    ///      parents to have only one record.
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

    /// @notice Validate one Safe's threshold, owner addresses, owner kinds and absence of
    ///         duplicate owners.
    /// @dev Each graph node must describe a supported quorum before traversal or storage can
    ///      rely on it.
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

    /// @notice Find a Safe among the populated records, returning `type(uint256).max` when
    ///         absent.
    /// @dev Traversal needs to distinguish first visits, shared children and missing records
    ///      without confusing unused allocation slots with graph entries.
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

    /// @notice Double the traversal buffers and copy the visited records and active-path flags.
    /// @dev Growing in memory lets traversal handle graphs larger than its initial allocation
    ///      while preserving cycle detection state.
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

    /// @notice Load one Safe's owners and threshold from the supplied record array.
    /// @dev This lets the common traversal validate an encoded graph without consulting live
    ///      source contracts. `context` is the array's memory pointer.
    function _loadRecord(bytes32 context, address safe) private pure returns (SafeOwner[] memory, uint256) {
        SafeAuthorityRecord[] memory records;
        assembly ("memory-safe") {
            records := context
        }
        uint256 index = _indexOf(records, records.length, safe);
        if (index == type(uint256).max) revert MissingAuthorityRecord(safe);
        return (records[index].owners, records[index].threshold);
    }

    /// @notice Read a live Safe's owners and threshold and classify each owner as EOA or nested
    ///         Safe.
    /// @dev Source graph derivation must capture both quorum and owner kinds because the
    ///      receiver verifies those kinds differently.
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

    /// @notice Make a read-only Safe query and reject a failed or undersized reply.
    /// @dev Graph derivation cannot accept an owner that fails to provide the expected
    ///      ownership data.
    function _ask(address safe, bytes4 selector, uint256 minimum) private view returns (bytes memory reply) {
        bool ok;
        (ok, reply) = safe.staticcall(abi.encodeWithSelector(selector));
        if (!ok || reply.length < minimum) revert NotASafe(safe);
    }

    /// @notice Recognize an account with no code or exactly the 23-byte EIP-7702 delegation
    ///         indicator.
    /// @dev Delegated EOAs still sign with their keys; treating them as nested Safes would
    ///      incorrectly require Safe ownership methods.
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
