// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Erc7930} from "src/addressing/Erc7930.sol";

/// @title ChainKey
/// @notice The protocol's single name for a destination: keccak256 of the canonical
///         ERC-7930 chain identifier.
///
/// @dev THE POINT IS THAT NOBODY HAS TO STORE ONE. A chainKey reads like an opaque hash,
///      which makes it look like configuration a caller must be handed. For eip155 it is
///      not: the ERC-7930 chain identifier is a pure function of the chain id, so the
///      source derives the destination's key from the plain `uint256` a signer already
///      recognizes, and the destination derives its own from `block.chainid`. Neither end
///      reads storage, and no developer ever passes a hash around.
///
/// @dev WHY THIS AND NOT THE RAW CHAIN ID. `submit` has to name a destination for two
///      different consumers, and they want different things:
///
///        1. The COMMITMENT DOMAIN, folded into `Commitment.hashCalls` and recomputed by the
///           receiver on the far side. It must be derivable there with zero configuration,
///           which rules out anything provider-specific.
///        2. The PROVIDER ROUTING ID: a LayerZero uint32 eid, a Hyperlane uint32 domain,
///           a Wormhole uint16, a CCIP uint64 selector. Per-protocol, and pure config.
///
///      A raw `uint256` chain id serves (1) only on EVM destinations and never serves (2).
///      A chainKey serves (1) on every VM and is what the registry already keys the
///      routing table by, so (2) is a lookup rather than a second argument.
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
