// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AuthorityUpdate} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "@crossecute/safe-guard/authority/ISourceAuthorityGuard.sol";
import {Call} from "../Call.sol";
import {Bytes} from "../signed/Bytes.sol";
import {SafeAuthorityRecord} from "../signed/types/SafeAuthorityTypes.sol";
import {AuthorityEntry, AuthorityGraph} from "./AuthorityGraph.sol";

/// @notice Draft #109 encoding helpers. Callers must validate canonical graphs before hashing.
library AuthorityUpdateEncoding {
    bytes32 internal constant GRAPH_DOMAIN = keccak256("Crossecute.AuthorityGraph.v1");
    // Solidity selectors intentionally use the first four bytes of the signature hash.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes4 internal constant MULTISEND_SELECTOR = bytes4(keccak256("multiSend(bytes)"));
    // Solidity selectors intentionally use the first four bytes of the signature hash.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes4 internal constant ADD_OWNER = bytes4(keccak256("addOwnerWithThreshold(address,uint256)"));
    // Solidity selectors intentionally use the first four bytes of the signature hash.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes4 internal constant REMOVE_OWNER = bytes4(keccak256("removeOwner(address,address,uint256)"));
    // Solidity selectors intentionally use the first four bytes of the signature hash.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes4 internal constant SWAP_OWNER = bytes4(keccak256("swapOwner(address,address,address)"));
    // Solidity selectors intentionally use the first four bytes of the signature hash.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes4 internal constant CHANGE_THRESHOLD = bytes4(keccak256("changeThreshold(uint256)"));

    error EmptyMutations();
    error InvalidMutation(uint256 index);
    error InvalidOwnershipBatch();

    function recordHash(SafeAuthorityRecord memory record) internal pure returns (bytes32) {
        return keccak256(abi.encode(record));
    }

    function entries(AuthorityGraph memory authority) internal pure returns (AuthorityEntry[] memory result) {
        result = new AuthorityEntry[](authority.nodes.length);
        for (uint256 i; i < result.length; ++i) {
            result[i] = AuthorityEntry(recordHash(authority.nodes[i].record), authority.nodes[i].position);
        }
    }

    /// @notice Content hash shared across destinations; source chain is part of graph identity.
    /// @dev entries[0] commits to the root's record, so the root address needs no separate
    ///      field. This helper alone authenticates neither graph shape nor signers.
    function graphHash(uint256 sourceChainId, AuthorityEntry[] memory graphEntries) internal pure returns (bytes32) {
        return keccak256(abi.encode(GRAPH_DOMAIN, sourceChainId, graphEntries));
    }

    function graphHash(uint256 sourceChainId, AuthorityGraph memory authority) internal pure returns (bytes32) {
        return graphHash(sourceChainId, entries(authority));
    }

    /// @notice Build the exact MultiSendCallOnly calldata of a one-SafeTx ownership change: the
    ///         guard's registerOwnershipChange, then the ordered zero-value owner self-calls.
    /// @dev The outer SafeTx DELEGATECALLs a pinned MultiSendCallOnly. Selector/length checks do
    ///      not replace actual Safe mutation derivation and post-state checks.
    function ownershipBatchData(address guard, address safe, AuthorityUpdate memory update, Call[] memory mutations)
        internal
        pure
        returns (bytes memory)
    {
        if (mutations.length == 0) revert EmptyMutations();
        bytes memory registration = abi.encodeCall(ISourceAuthorityGuard.registerOwnershipChange, (update));
        bytes memory packed = abi.encodePacked(uint8(0), guard, uint256(0), registration.length, registration);
        for (uint256 i; i < mutations.length; ++i) {
            Call memory c = mutations[i];
            if (c.target != safe || c.value != 0 || c.data.length < 4) revert InvalidMutation(i);
            bytes memory data = c.data;
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(data, 32))
            }
            bool valid = (selector == ADD_OWNER && data.length == 68)
                || (selector == REMOVE_OWNER && data.length == 100) || (selector == SWAP_OWNER && data.length == 100)
                || (selector == CHANGE_THRESHOLD && data.length == 36);
            if (!valid) revert InvalidMutation(i);
            packed = bytes.concat(packed, abi.encodePacked(uint8(0), c.target, uint256(0), data.length, data));
        }
        return abi.encodeWithSelector(MULTISEND_SELECTOR, packed);
    }

    /// @notice Recover the update and mutations from ownership-change batch calldata.
    /// @dev Strict: the result must re-encode to exactly data, so no alternative encoding of one
    ///      batch is accepted.
    function decodeOwnershipBatch(address guard, address safe, bytes memory data)
        internal
        pure
        returns (AuthorityUpdate memory update, Call[] memory mutations)
    {
        bytes memory packed = abi.decode(Bytes.arguments(data, MULTISEND_SELECTOR), (bytes));
        uint256 count;
        for (uint256 at; at < packed.length; ++count) {
            at = _nextEntry(packed, at);
        }
        if (count < 2) revert InvalidOwnershipBatch();

        mutations = new Call[](count - 1);
        uint256 cursor;
        for (uint256 i; i < count; ++i) {
            uint256 next = _nextEntry(packed, cursor);
            address target;
            uint256 value;
            assembly ("memory-safe") {
                let at := add(add(packed, 0x20), cursor)
                target := shr(96, mload(add(at, 1)))
                value := mload(add(at, 21))
            }
            bytes memory callData = Bytes.slice(packed, cursor + 85, next - cursor - 85);
            if (i == 0) {
                bytes memory arguments =
                    Bytes.arguments(callData, ISourceAuthorityGuard.registerOwnershipChange.selector);
                update = abi.decode(arguments, (AuthorityUpdate));
            } else {
                mutations[i - 1] = Call(target, value, callData);
            }
            cursor = next;
        }
        if (keccak256(ownershipBatchData(guard, safe, update, mutations)) != keccak256(data)) {
            revert InvalidOwnershipBatch();
        }
    }

    /// @dev One packed MultiSend entry: uint8 operation, address to, uint256 value, uint256
    ///      length, then length bytes. Returns the offset after it.
    function _nextEntry(bytes memory packed, uint256 at) private pure returns (uint256) {
        if (packed.length - at < 85) revert InvalidOwnershipBatch();
        uint256 length;
        assembly ("memory-safe") {
            length := mload(add(add(add(packed, 0x20), at), 53))
        }
        if (length > packed.length - at - 85) revert InvalidOwnershipBatch();
        return at + 85 + length;
    }
}
