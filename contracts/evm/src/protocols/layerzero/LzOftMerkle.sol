// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";

/// @notice Leaf hashes and ordered proofs for the OFT factory's destination commitment.
library LzOftMerkle {
    /// @notice A destination's leaf in a conduit's `destRoot`.
    /// @dev Hashed twice, so a 64-byte inner node of the tree is never read as a leaf.
    function leaf(bytes32 chainKey, uint32 eid, address oft) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(chainKey, eid, oft))));
    }

    /// @notice The root `destRoot` is, over `leaves` in the order given.
    /// @dev On a copy, so the caller's leaves are left as they were.
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory level = new bytes32[](leaves.length);
        for (uint256 i; i < leaves.length; ++i) {
            level[i] = leaves[i];
        }
        for (uint256 n = level.length; n > 1;) {
            n = _up(level, n);
        }
        return level[0];
    }

    /// @notice The sibling path `root` hashes leaf `index` along, which `MerkleProof.verify`
    ///         checks against it.
    /// @dev `level` is overwritten level by level, so the caller passes a copy.
    function proof(bytes32[] memory level, uint256 index) internal pure returns (bytes32[] memory siblings) {
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

    /// @dev One level up, in place: neighbours paired with the commutative hash
    ///      `MerkleProof.verify` uses, and an unpaired last node carried up unchanged, so its
    ///      proof skips that level. Returns the new level's length.
    function _up(bytes32[] memory level, uint256 n) private pure returns (uint256) {
        for (uint256 i; i < n / 2; ++i) {
            level[i] = Hashes.commutativeKeccak256(level[2 * i], level[2 * i + 1]);
        }
        if (n % 2 == 1) level[n / 2] = level[n - 1];
        return (n + 1) / 2;
    }
}
