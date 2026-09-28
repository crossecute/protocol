// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Erc7930} from "src/addressing/Erc7930.sol";

/// @title ChainKey
/// @notice The protocol's single name for a destination: keccak256 of the canonical
///         ERC-7930 chain identifier.
///
/// @dev For eip155 nobody stores one: the source derives the destination's key from its
///      `uint256` chain id and the destination derives its own from `block.chainid`.
///
/// @dev It is both the commitment domain, folded into `Commitment.hashCalls` and recomputed
///      by the receiver with no configuration, and the key every routing table is indexed by
///      (routes and counterparts on a transceiver, chain data in the registry). A raw chain
///      id would serve the first only on EVM destinations.
library ChainKey {
    /// @notice The key for an eip155 chain. Pure: no storage, no registry, no round trip.
    function forEvm(uint256 chainId) internal pure returns (bytes32) {
        return keccak256(Erc7930.encodeEvmChain(chainId));
    }

    /// @notice This chain's own key, as the destination-side receiver computes it.
    /// @dev The counterpart to `forEvm`, and the reason the commitment domain needs no
    ///      configuration on the destination. A non-EVM receiver overrides its equivalent
    ///      with a literal for its own chain identifier: a property of the deployment
    ///      target, not something an operator sets.
    function local() internal view returns (bytes32) {
        return forEvm(block.chainid);
    }

    /// @notice The key for any chain, from an ERC-7930 envelope.
    /// @dev Accepts an account envelope as well as a bare chain identifier;
    ///      `toChainIdentifier` reduces it, so every address on a chain yields one key.
    ///      `parseStrict` runs inside, so a non-canonical framing reverts here rather
    ///      than becoming a key nothing else can reproduce.
    function fromIdentifier(bytes memory identifier) internal pure returns (bytes32) {
        return keccak256(Erc7930.toChainIdentifier(identifier));
    }
}
