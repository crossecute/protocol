// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";

/// @notice The transceiver on the home chain. One instance, administered by the crossecute
///         msig, shared by every user's transmitter.
///
/// @dev IT CARRIES NO PROVIDER VOCABULARY AT ALL, AND THAT IS WHAT ERC-7786 BOUGHT, EXACTLY
///      AS ON THE LAYERZERO TEMPLATE. A gateway takes a recipient that NAMES ITS OWN CHAIN, so
///      there is nothing to translate and the route slot holds that chain's ERC-7930
///      identifier. A native Wormhole binding needs a codec and a chainKey table of its own,
///      since `sendPayloadToEvm` still takes a `uint16 targetChain`, the "Wormhole Chain ID"
///      format: its own per-chain enumeration, not an EVM chain id and not the string chain
///      names Wormhole's off-chain SDK uses for developer convenience (that mapping never
///      reaches Solidity). `uint16` is the smallest of the four provider widths surveyed so
///      far and fits `ProviderChainId`'s `uint256` storage the same way the other three do.
///
/// @dev Does NOT inherit a transmitter, for the same reason as every other binding: a
///      transceiver is shared infrastructure the msig administers and a transmitter is
///      per-user, owned by its user.
///
/// @dev ONE RELAYER ADDRESS SERVES BOTH DIRECTIONS. `sendPayloadToEvm`/`quoteEVMDeliveryPrice`
///      (send) and the contract that calls `receiveWormholeMessages` (receive) are the same
///      `IWormholeRelayer` deployment on a given chain, so `GATEWAY_ROLE` names one address
///      here, not two. See
///      `docs/provider-research.md#6-wormhole-core-vs-the-relayer-two-different-bindings`.
contract WormholeHubTransceiver is HubTransceiverBase {
    /// @dev NO RECEIVER IMPLEMENTATION, because a hub never makes a receiver. The
    ///      manufacturing half lives on the spoke; see `TransceiverBase`.
    function initialize(
        address owner_,
        address treasury_,
        address[] calldata gateways,
        address transmitterImplementation_
    ) external initializer {
        __HubTransceiverBase_init(owner_, treasury_, gateways, transmitterImplementation_);
    }

    /// @notice NO GATEWAY IS GRANTED, so this contract accepts and sends through nothing.
    /// @dev That is the honest state of a binding with no Wormhole behind it. A real binding
    ///      grants `GATEWAY_ROLE` to the Wormhole Relayer in the initializer, which is where
    ///      the address is known; the absence fails loudly on the first message rather than
    ///      quietly on a forged one.
    ///
    /// @dev NO WRITTEN R3.3 EXCEPTION IS NEEDED HERE, THE SAME CONCLUSION AS CCIP AND
    ///      HYPERLANE. The Relayer's callback tells this contract who sent a message
    ///      (`sourceAddress`, `sourceChainId`) but has no per-app "enrolled peer" concept of
    ///      its own to check it against before calling `receiveWormholeMessages` — unlike
    ///      LayerZero's OApp, which authenticates a peer inside `_lzReceive` itself. A binding
    ///      that authenticates solely through `_authenticateOrigin` has exactly one origin
    ///      check, in exactly one place, matching `_onInbound`'s stated rule with nothing to
    ///      write an exception for.

}
