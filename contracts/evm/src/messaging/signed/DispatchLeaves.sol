// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {OrderedMerkle} from "src/messaging/OrderedMerkle.sol";
import {ExecutionLeaf} from "src/messaging/signed/types/SignedDispatchTypes.sol";

/// @notice Leaf hashes and proof verification for a Safe-signed dispatch tree, the
///         `OrderedMerkle` tree the guard's `publishLeaves` builds.
/// @dev The bootstrap and execution encodings have heads of four and six words, so the first
///      offset word differs and neither leaf can be presented as the other.
library DispatchLeaves {
    error InvalidProof();

    /// @notice Hash every execution-leaf field, attributes included.
    function hash(ExecutionLeaf memory leaf) internal pure returns (bytes32) {
        return OrderedMerkle.leafHash(
            abi.encode(leaf.destination, leaf.nonce, leaf.validAfter, leaf.deadline, leaf.calls, leaf.attributes)
        );
    }

    /// @notice Hash the execution fields without the provider attributes.
    /// @dev Identifies an executed batch at its nonce even when it is reapproved with different
    ///      delivery options.
    function executionId(ExecutionLeaf memory leaf) internal pure returns (bytes32) {
        return
            OrderedMerkle.leafHash(abi.encode(leaf.destination, leaf.nonce, leaf.validAfter, leaf.deadline, leaf.calls));
    }

    function requireProof(bytes32[] memory proof, bytes32 root, bytes32 leafHash) internal pure {
        if (!MerkleProof.verify(proof, root, leafHash)) revert InvalidProof();
    }
}
