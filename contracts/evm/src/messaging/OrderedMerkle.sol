// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";

/// @notice The protocol's one Merkle tree: the guard's `publishLeaves` tree for signed dispatch
///         and the `layerzero-oft` destination root. Leaves keep the caller's order, an internal
///         node hashes its children smaller first, and a level's unpaired last node moves up
///         unchanged, so its proof holds no entry for that level. `MerkleProof.verify` checks
///         the proofs.
library OrderedMerkle {
    error NoLeaves();
    error IndexOutOfRange(uint256 index, uint256 count);

    /// @notice A leaf's hash from its `abi.encode`d fields.
    /// @dev Hashed twice, so a 64-byte internal node is never a leaf preimage.
    function leafHash(bytes memory fields) internal pure returns (bytes32) {
        return keccak256(abi.encode(keccak256(fields)));
    }

    /// @notice The root over `leafHashes` in the order given. One leaf is its own root.
    function root(bytes32[] memory leafHashes) internal pure returns (bytes32) {
        bytes32[] memory level = _copy(leafHashes);
        for (uint256 n = level.length; n > 1;) {
            n = _up(level, n);
        }
        return level[0];
    }

    /// @notice The sibling path from `leafHashes[index]` to `root(leafHashes)`; empty for one leaf.
    function proof(bytes32[] memory leafHashes, uint256 index) internal pure returns (bytes32[] memory siblings) {
        if (index >= leafHashes.length) revert IndexOutOfRange(index, leafHashes.length);
        bytes32[] memory level = _copy(leafHashes);
        // A tree of fewer than 2^64 leaves has fewer than 64 levels.
        bytes32[] memory scratch = new bytes32[](64);
        uint256 depth;
        for (uint256 n = level.length; n > 1; index /= 2) {
            uint256 sibling = index ^ 1;
            if (sibling < n) scratch[depth++] = level[sibling];
            n = _up(level, n);
        }
        siblings = new bytes32[](depth);
        for (uint256 i; i < depth; ++i) {
            siblings[i] = scratch[i];
        }
    }

    function _copy(bytes32[] memory leafHashes) private pure returns (bytes32[] memory level) {
        if (leafHashes.length == 0) revert NoLeaves();
        level = new bytes32[](leafHashes.length);
        for (uint256 i; i < leafHashes.length; ++i) {
            level[i] = leafHashes[i];
        }
    }

    /// @dev One level up, in place: node i reads entries 2i and 2i + 1, which no earlier node has
    ///      overwritten. Returns the new level's length.
    function _up(bytes32[] memory level, uint256 n) private pure returns (uint256) {
        for (uint256 i; i < n / 2; ++i) {
            level[i] = Hashes.commutativeKeccak256(level[2 * i], level[2 * i + 1]);
        }
        if (n % 2 == 1) level[n / 2] = level[n - 1];
        return (n + 1) / 2;
    }
}
