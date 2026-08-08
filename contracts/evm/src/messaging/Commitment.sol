// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ChainKey} from "src/addressing/ChainKey.sol";
import {Call, Calls} from "src/messaging/Call.sol";
import {Blake2b256} from "src/derivation/Blake2b256.sol";

/// @notice The hash a destination computes its commitments with.
///
/// @dev THE FOLD IS FIXED; ONLY THE PRIMITIVE VARIES. That is a deliberate narrowing, and
///      it is worth being honest about what it gives up. A fully VM-native commitment
///      would be TON's cell hash (sha256 over a cell tree, because a TVM cell holds only
///      1023 bits and a payload is therefore a tree) or Starknet's `poseidon_hash_span`
///      over a felt array, neither of which is a byte-oriented fold, and neither of which
///      the hub could reproduce to show a signer what they are approving. Holding the
///      fold fixed keeps both sides able to compute the same value. The cost is that a
///      non-EVM receiver implements a byte fold rather than its idiomatic digest.
///
/// @dev keccak256 IS THE ONLY ONE AN EVM RECEIVER EVER USES, because an EVM receiver runs
///      on an EVM chain. The rest exist for the source side, where the hub builds a
///      commitment a *different* VM will recompute.
enum Scheme {
    /// EVM. The opcode.
    Keccak256,
    /// TON. `sha256` is an EVM builtin, so this stays computable on both sides.
    Sha256,
    /// Cardano. EIP-152 precompile 0x09: see `Blake2b256`. This is the member that
    /// forces every dispatching function to `view` rather than `pure`.
    Blake2b256Scheme,
    /// Starknet. DECLARED, NOT IMPLEMENTED HERE. Poseidon over the Starknet field needs
    /// the exact round constants and MDS matrix; a single wrong constant produces a
    /// silently wrong digest, so it is not written from memory. Until it is ported and
    /// checked against `test/vectors/starknet.json`, a Starknet commitment has to be
    /// computed off-chain and approved through the digest-only overload.
    Poseidon
}

/// @title Commitment
/// @notice The commitment over a call array, bound to exactly one destination.
///
/// @dev THE DOMAIN IS A CHAINKEY, NOT A CHAIN ID. Receivers sit at deterministic
///      addresses across chains, which is precisely the situation where a cross-chain
///      replay works, so the domain has to be folded in. It is `ChainKey` rather than
///      `block.chainid` because the destination is not always an EVM chain: a Sui or
///      Solana receiver has no `uint256` chain id to fold, but every chain has an
///      ERC-7930 identifier. The EVM case still derives it from `block.chainid` alone,
///      so nothing on the destination has to be configured for this to work.
///
/// @dev THE COMMITMENT IS DEFINED OVER OPAQUE ELEMENTS, AND THAT IS WHAT KEEPS IT
///      PORTABLE. The fold never looks inside an element, so the hub's contracts never
///      need to understand a Solana instruction or a Move entry function: there is no
///      Borsh and no BCS anywhere in Solidity. The typed overload is a convenience for
///      EVM destinations layered on top, not a second scheme: `Calls.encode` produces
///      exactly the element the opaque path would carry, so both spellings of one payload
///      produce one hash. A payload approved as `Call[]` can be delivered as `bytes[]`,
///      which is what lets the wire format carry either form (see `Payload`).
library Commitment {
    /// @dev The scheme has no implementation on this chain, so a commitment for it must be
    ///      computed off-chain and approved as a digest.
    error SchemeNotComputable(Scheme scheme);

    /// @notice The hash a receiver on THIS chain will require, for typed calls.
    function hashCalls(Call[] memory calls) internal view returns (bytes32) {
        return hashCalls(ChainKey.local(), calls);
    }

    /// @notice The same value, from typed calls.
    ///
    /// @dev Equal to the opaque overload applied to `Calls.encodeAll(calls)`, element for
    ///      element. Asserted in `test/PayloadEncoding.t.sol` rather than assumed: if the
    ///      two ever diverge, a payload approved in one form silently stops matching in
    ///      the other, and it fails only on a live message.
    ///
    /// @dev EVERY ARRAY PARAMETER HERE IS `memory`. Solidity will not overload on data
    ///      location, so a `calldata` twin needed a different name, which is the only
    ///      reason `hashElements` ever existed. One location, one name.
    function hashCalls(
        bytes32 destinationChainKey,
        Call[] memory calls
    ) internal pure returns (bytes32 hashed) {
        hashed = _seed(destinationChainKey);
        uint256 len = calls.length;
        for (uint256 i = 0; i < len; i++) {
            hashed = _fold(hashed, Calls.hash(calls[i]));
        }
    }

    /// @notice CANONICAL. The hash a receiver on `destinationChainKey` requires, over the
    ///         portable opaque elements.
    /// @dev The source calls this with the DESTINATION's key. Passing the local one
    ///      produces a commitment nothing on the far side can ever match, and it fails
    ///      only on a live message.
    function hashCalls(
        bytes32 destinationChainKey,
        bytes[] memory elements
    ) internal pure returns (bytes32 hashed) {
        hashed = _seed(destinationChainKey);
        uint256 len = elements.length;
        for (uint256 i = 0; i < len; i++) {
            hashed = _fold(hashed, keccak256(elements[i]));
        }
    }

    function isHashedCall(
        bytes32 hashed,
        Call[] memory calls
    ) internal view returns (bool) {
        return hashed == hashCalls(calls);
    }

    /* ============================ non-EVM destinations =========================== */

    /// @notice The commitment a destination using `scheme` will require.
    ///
    /// @dev FOR THE SOURCE SIDE ONLY. An EVM receiver always uses keccak256, so the
    ///      overloads above are what it calls and they stay `pure`. This exists because a
    ///      transmitter on the home chain builds commitments for chains that hash
    ///      differently,
    ///      and if it built them with the wrong scheme the destination would simply never
    ///      match, which fails only on a live message.
    ///
    /// @dev `view`, NOT `pure`, AND THE REASON IS ONE MEMBER. `Blake2b256` reaches the
    ///      EIP-152 precompile through `staticcall`, which Solidity forbids inside `pure`.
    ///      The same tax was already paid by `IVmDeriver` for the same precompile. It
    ///      costs nothing where it matters: these are read through `eth_call` when a
    ///      signer checks a payload, so gas is not charged at all.
    function hashCalls(
        Scheme scheme,
        bytes32 destinationChainKey,
        bytes[] memory elements
    ) internal view returns (bytes32 hashed) {
        hashed = _hash(scheme, abi.encode(destinationChainKey));
        uint256 len = elements.length;
        for (uint256 i = 0; i < len; i++) {
            hashed = _hash(scheme, abi.encodePacked(hashed, _hash(scheme, elements[i])));
        }
    }

    /// @notice The same value, from typed calls.
    function hashCalls(
        Scheme scheme,
        bytes32 destinationChainKey,
        Call[] memory calls
    ) internal view returns (bytes32 hashed) {
        hashed = _hash(scheme, abi.encode(destinationChainKey));
        uint256 len = calls.length;
        for (uint256 i = 0; i < len; i++) {
            hashed =
                _hash(scheme, abi.encodePacked(hashed, _hash(scheme, Calls.encode(calls[i]))));
        }
    }

    /// @notice Whether this chain can compute `scheme` at all.
    /// @dev Lets a caller check before building a payload, rather than discovering it in a
    ///      revert. False only for `Poseidon` today.
    function isComputable(Scheme scheme) internal pure returns (bool) {
        return scheme != Scheme.Poseidon;
    }

    /* ================================== internals =============================== */

    /// @dev An empty array hashes to the seed alone, which is non-zero and therefore a
    ///      valid commitment. `execute` refuses an empty payload because nothing else
    ///      establishes intent there; `finalize` does not, because the commitment is the
    ///      intent.
    function _seed(bytes32 destinationChainKey) private pure returns (bytes32) {
        return keccak256(abi.encode(destinationChainKey));
    }

    function _fold(bytes32 acc, bytes32 elementHash) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(acc, elementHash));
    }

    /// @dev A scheme with no implementation here reverts rather than falling back. A
    ///      silent fallback to keccak256 would hand back a well-formed commitment that the
    ///      destination can never match, and it would fail only on a live message.
    function _hash(Scheme scheme, bytes memory data) private view returns (bytes32) {
        if (scheme == Scheme.Keccak256) return keccak256(data);
        if (scheme == Scheme.Sha256) return sha256(data);
        if (scheme == Scheme.Blake2b256Scheme) return Blake2b256.hash(data);
        revert SchemeNotComputable(scheme);
    }
}
