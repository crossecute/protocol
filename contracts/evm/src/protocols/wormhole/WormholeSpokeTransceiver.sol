// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";

/// @notice The transceiver on every chain that is not the home chain.
///
/// @dev THE ENTIRE ROUTING LAYER IS THREE WRITE-ONCE VALUES: `homeChainKey`, `homeRoute()`
///      holding that chain's ERC-7930 identifier, and `homeTransceiver()` holding the hub's
///      address. No registry to read, no table to maintain, no destination to choose. Same
///      shape as `LzSpokeTransceiver`; nothing about this layer is provider-specific.
///
/// @dev THE ROUTE IS THE CHAIN IDENTIFIER, NOT WORMHOLE'S `uint16` CHAIN ID FOR IT, which
///      makes `keccak256(homeRoute()) == homeChainKey` true by construction rather than by
///      configuration, and is what an ERC-7786 recipient is built from.
contract WormholeSpokeTransceiver is SpokeTransceiverBase {
    /// @param homeChainKey_ keccak256 of the home chain's ERC-7930 chain identifier.
    /// @param homeChainIdentifier_ That identifier itself. It is passed rather than derived
    ///        because a chainKey is a hash and cannot be reversed, and it is checked
    ///        against `homeChainKey_` so the pair cannot disagree.
    /// @param homeTransceiver_ The hub, in this chain's address format. Fixed for the life
    ///        of the contract: there is no setter, by design.
    /// @dev THIS IS THE PARITY SPOKE, AND IT DOES NOT TAKE THE DIVERGENCE FLAG. It inherits
    ///      `TransceiverBase.predictCrossAccount`, which is Ethereum's CREATE2 formula and
    ///      exactly what the hub recomputes, so accounts here do NOT diverge and the flag is
    ///      `false` by construction rather than by configuration. A chain that really
    ///      diverges needs `WormholeZkSyncSpokeTransceiver` or `WormholeTronSpokeTransceiver`
    ///      instead.
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_
    ) external initializer {
        __SpokeTransceiverBase_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            false
        );
    }

    /// @notice NO GATEWAY IS GRANTED, so this contract accepts and sends through nothing.
    /// @dev That is the honest state of a binding with no Wormhole behind it. A real binding
    ///      grants `GATEWAY_ROLE` to the Wormhole Relayer in the initializer, which is where
    ///      the address is known; the absence fails loudly on the first message rather than
    ///      quietly on a forged one. See `WormholeHubTransceiver` for why no R3.3-style
    ///      written exception is needed for the authentication order here either.

}
