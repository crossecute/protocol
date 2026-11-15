// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Call} from "../Call.sol";
import {Bytes} from "../signed/Bytes.sol";
import {SafeAuthorityRecord, SafeOwner, OWNER_EOA} from "../signed/types/SafeAuthorityTypes.sol";
import {MAX_SAFE_OWNERS} from "./AuthorityGraph.sol";
import {AuthorityUpdateEncoding} from "./AuthorityUpdateEncoding.sol";

/// @notice Owner-change derivation shared by the source guard and destination registries.
/// @dev Mirrors Safe 1.5.0 OwnerManager: an added owner goes to the front, a swapped owner keeps
///      its place, and each step accepts exactly what Safe accepts, plus the 16-owner cap.
library AuthorityMutations {
    address internal constant SENTINEL = address(1);

    error TooManyOwners(uint256 index);
    error MutationOwner(uint256 index, address owner);
    error MutationPredecessor(uint256 index, address prevOwner, address owner);
    error MutationThreshold(uint256 index, uint256 threshold, uint256 ownerCount);
    error MutationResultMismatch();

    /// @notice Apply ordered owner self-calls to `current` and require the result to equal
    ///         `expected`.
    /// @dev An added owner takes its kind from `expected`; an owner that stays keeps its kind, so
    ///      a kind changes only by removing and re-adding the owner. An owner added and removed
    ///      within the batch is absent from `expected` and is carried as EOA-kind.
    function applyMutations(
        SafeAuthorityRecord memory current,
        Call[] memory mutations,
        SafeAuthorityRecord memory expected
    ) internal pure {
        address safe = current.safe;
        uint256 count = current.owners.length;
        if (count > MAX_SAFE_OWNERS) revert TooManyOwners(type(uint256).max);
        SafeOwner[] memory owners = new SafeOwner[](MAX_SAFE_OWNERS);
        for (uint256 i; i < count; ++i) {
            owners[i] = current.owners[i];
        }
        uint256 threshold = current.threshold;

        for (uint256 i; i < mutations.length; ++i) {
            Call memory c = mutations[i];
            if (c.target != safe || c.value != 0 || c.data.length < 4) {
                revert AuthorityUpdateEncoding.InvalidMutation(i);
            }
            // forge-lint: disable-next-line(unsafe-typecast) the first four bytes, after the length check
            bytes4 selector = bytes4(c.data);
            bytes memory arguments = Bytes.arguments(c.data, selector);
            if (selector == AuthorityUpdateEncoding.ADD_OWNER) {
                (address owner, uint256 newThreshold) = abi.decode(arguments, (address, uint256));
                _requireNewOwner(i, safe, owners, count, owner);
                if (count == MAX_SAFE_OWNERS) revert TooManyOwners(i);
                for (uint256 j = count; j != 0; --j) {
                    owners[j] = owners[j - 1];
                }
                owners[0] = SafeOwner(owner, _kindIn(expected, owner));
                ++count;
                threshold = _checkThreshold(i, newThreshold, count);
            } else if (selector == AuthorityUpdateEncoding.REMOVE_OWNER) {
                (address prevOwner, address owner, uint256 newThreshold) =
                    abi.decode(arguments, (address, address, uint256));
                uint256 at = _requirePredecessor(i, owners, count, prevOwner, owner);
                --count;
                for (uint256 j = at; j < count; ++j) {
                    owners[j] = owners[j + 1];
                }
                threshold = _checkThreshold(i, newThreshold, count);
            } else if (selector == AuthorityUpdateEncoding.SWAP_OWNER) {
                (address prevOwner, address oldOwner, address newOwner) =
                    abi.decode(arguments, (address, address, address));
                _requireNewOwner(i, safe, owners, count, newOwner);
                uint256 at = _requirePredecessor(i, owners, count, prevOwner, oldOwner);
                owners[at] = SafeOwner(newOwner, _kindIn(expected, newOwner));
            } else if (selector == AuthorityUpdateEncoding.CHANGE_THRESHOLD) {
                threshold = _checkThreshold(i, abi.decode(arguments, (uint256)), count);
            } else {
                revert AuthorityUpdateEncoding.InvalidMutation(i);
            }
        }

        assembly ("memory-safe") {
            mstore(owners, count)
        }
        SafeAuthorityRecord memory result = SafeAuthorityRecord(safe, threshold, owners);
        if (AuthorityUpdateEncoding.recordHash(result) != AuthorityUpdateEncoding.recordHash(expected)) {
            revert MutationResultMismatch();
        }
    }

    /// @dev Safe's add/swap rule for the incoming owner: not zero, the sentinel, the Safe or a
    ///      current owner.
    function _requireNewOwner(uint256 index, address safe, SafeOwner[] memory owners, uint256 count, address owner)
        private
        pure
    {
        if (owner == address(0) || owner == SENTINEL || owner == safe || _indexOf(owners, count, owner) < count) {
            revert MutationOwner(index, owner);
        }
    }

    /// @dev Safe's `owners[prevOwner] == owner` check on the list: prevOwner is the entry before
    ///      owner, or the sentinel when owner is first. Returns owner's index.
    function _requirePredecessor(
        uint256 index,
        SafeOwner[] memory owners,
        uint256 count,
        address prevOwner,
        address owner
    ) private pure returns (uint256 at) {
        at = _indexOf(owners, count, owner);
        if (owner == SENTINEL || at == count || prevOwner != (at == 0 ? SENTINEL : owners[at - 1].owner)) {
            revert MutationPredecessor(index, prevOwner, owner);
        }
    }

    /// @dev The threshold Safe accepts after a step: nonzero and at most the owner count. Safe
    ///      skips changeThreshold when the value is unchanged, but an unchanged threshold always
    ///      meets this, so the accepted set is the same.
    function _checkThreshold(uint256 index, uint256 threshold, uint256 count) private pure returns (uint256) {
        if (threshold == 0 || threshold > count) revert MutationThreshold(index, threshold, count);
        return threshold;
    }

    function _indexOf(SafeOwner[] memory owners, uint256 count, address owner) private pure returns (uint256 i) {
        while (i < count && owners[i].owner != owner) {
            ++i;
        }
    }

    function _kindIn(SafeAuthorityRecord memory record, address owner) private pure returns (uint8) {
        for (uint256 i; i < record.owners.length; ++i) {
            if (record.owners[i].owner == owner) return record.owners[i].kind;
        }
        return OWNER_EOA;
    }
}
