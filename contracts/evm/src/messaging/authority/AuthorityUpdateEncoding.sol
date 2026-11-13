// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Call} from "../Call.sol";
import {AuthorityGraph} from "./AuthorityGraph.sol";

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

    /// @notice Content hash shared across destinations; source chain is part of graph identity.
    /// @dev This helper alone authenticates neither graph shape nor signers.
    function graphHash(uint256 sourceChainId, AuthorityGraph memory authority) internal pure returns (bytes32) {
        return keccak256(abi.encode(GRAPH_DOMAIN, sourceChainId, authority));
    }

    /// @notice Build exact MultiSendCallOnly calldata for an ordered zero-value ownership batch.
    /// @dev The outer SafeTx uses DELEGATECALL to a pinned helper, including one-element batches.
    ///      Selector/length checks do not replace actual Safe mutation derivation and post-state checks.
    function mutationBatchData(address safe, Call[] memory mutations) internal pure returns (bytes memory) {
        if (mutations.length == 0) revert EmptyMutations();
        bytes memory packed;
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
}
