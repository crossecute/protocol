// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ChainKey} from "src/addressing/ChainKey.sol";
import {Call, Calls} from "src/messaging/Call.sol";
import {Blake2b256} from "src/derivation/Blake2b256.sol";

/// @notice The hash a destination computes its commitments with.
///
/// @dev The fold is fixed and only the primitive varies, so the home can reproduce any
///      destination's commitment for a signer. The cost is that a non-EVM receiver implements
///      a byte fold rather than its native digest (TON's cell hash, Starknet's
///      `poseidon_hash_span`).
///
/// @dev An EVM receiver only ever uses keccak256; the others are for the home building a
///      commitment another VM will recompute.
enum Scheme {
    /// EVM. The opcode.
    Keccak256,
    /// Ton. `sha256` is an EVM builtin, so this stays computable on both sides.
    Sha256,
    /// Cardano. EIP-152 precompile 0x09: see `Blake2b256`. The reason dispatching
    /// functions are `view` rather than `pure`.
    Blake2b256Scheme,
    /// Starknet. Declared, not implemented: Poseidon needs the exact round constants and MDS
    /// matrix, checked against vectors (`docs/todo.md` §4). Until then a Starknet commitment
    /// is computed off-chain and carried in an element calling that receiver's `commit`.
    Poseidon
}

/// @title Commitment
/// @notice The commitment over a call array, bound to exactly one destination.
///
/// @dev Seeded with the destination's chainKey, since accounts share addresses across chains
///      and a commitment must not replay between them. A chainKey rather than a chain id
///      because non-EVM chains have none; on the EVM it still derives from `block.chainid`.
///
/// @dev Defined over opaque elements, which it never looks inside, so no VM's call format is
///      parsed in Solidity. The typed overloads produce the same hash, since `Calls.encode`
///      yields exactly the opaque element.
library Commitment {
    /// @dev The scheme has no implementation on this chain, so a commitment for it must be
    ///      computed off-chain and approved as a digest.
    error SchemeNotComputable(Scheme scheme);
    /// @dev An empty array would hash to the seed alone, an approval that runs nothing.
    error EmptyCommitment();

    /// @notice The hash a receiver on this chain will require, for typed calls.
    function hashCalls(Call[] memory calls) internal view returns (bytes32) {
        return hashCalls(ChainKey.local(), calls);
    }

    /// @notice The same value, from typed calls.
    /// @dev Equal to the opaque overload over `Calls.encodeAll(calls)`, asserted in
    ///      `test/PayloadEncoding.t.sol`. Array parameters are `memory` throughout because
    ///      Solidity will not overload on data location.
    function hashCalls(bytes32 destinationChainKey, Call[] memory calls) internal pure returns (bytes32 hashed) {
        uint256 len = calls.length;
        if (len == 0) revert EmptyCommitment();
        hashed = _seed(destinationChainKey);
        for (uint256 i = 0; i < len; i++) {
            hashed = _fold(hashed, Calls.hash(calls[i]));
        }
    }

    /// @notice Canonical: the hash a receiver on `destinationChainKey` requires, over the
    ///         portable opaque elements.
    /// @dev The source passes the destination's key; the local one yields a commitment the
    ///      far side never matches.
    function hashCalls(bytes32 destinationChainKey, bytes[] memory elements) internal pure returns (bytes32 hashed) {
        uint256 len = elements.length;
        if (len == 0) revert EmptyCommitment();
        hashed = _seed(destinationChainKey);
        for (uint256 i = 0; i < len; i++) {
            hashed = _fold(hashed, keccak256(elements[i]));
        }
    }

    /* ============================ non-EVM destinations =========================== */

    /// @notice The commitment a destination using `scheme` will require.
    /// @dev Source side only; EVM receivers use the keccak overloads above. `view` for
    ///      `Blake2b256`'s precompile `staticcall`, read through `eth_call` by a signer.
    function hashCalls(Scheme scheme, bytes32 destinationChainKey, bytes[] memory elements)
        internal
        view
        returns (bytes32 hashed)
    {
        uint256 len = elements.length;
        if (len == 0) revert EmptyCommitment();
        hashed = _hash(scheme, abi.encode(destinationChainKey));
        for (uint256 i = 0; i < len; i++) {
            hashed = _hash(scheme, abi.encodePacked(hashed, _hash(scheme, elements[i])));
        }
    }

    /// @notice The same value, from typed calls.
    /// @dev Delegates to the opaque overload over `Calls.encodeAll`, so both spellings share
    ///      one fold.
    function hashCalls(Scheme scheme, bytes32 destinationChainKey, Call[] memory calls)
        internal
        view
        returns (bytes32)
    {
        return hashCalls(scheme, destinationChainKey, Calls.encodeAll(calls));
    }

    /// @notice Whether this chain can compute `scheme` at all. False only for `Poseidon`.
    function isComputable(Scheme scheme) internal pure returns (bool) {
        return scheme != Scheme.Poseidon;
    }

    /* ================================== internals =============================== */

    function _seed(bytes32 destinationChainKey) private pure returns (bytes32) {
        return keccak256(abi.encode(destinationChainKey));
    }

    function _fold(bytes32 acc, bytes32 elementHash) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(acc, elementHash));
    }

    /// @dev Reverts for a scheme with no implementation here rather than falling back to a
    ///      keccak256 digest the destination could never match.
    function _hash(Scheme scheme, bytes memory data) private view returns (bytes32) {
        if (scheme == Scheme.Keccak256) return keccak256(data);
        if (scheme == Scheme.Sha256) return sha256(data);
        if (scheme == Scheme.Blake2b256Scheme) return Blake2b256.hash(data);
        revert SchemeNotComputable(scheme);
    }
}
