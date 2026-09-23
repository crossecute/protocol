// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";

/// @notice Transceiver on the home chain. One instance, msig-administered.
/// @dev No provider vocabulary in the route table (ERC-7786). A real binding needs its own
///      chainKey<->id table: `sendPayloadToEvm` takes a `uint16 targetChain` ("Wormhole
///      Chain ID" — its own enumeration, not an EVM chain id or the off-chain SDK's string
///      names). Fits `ProviderChainId`'s `uint256` like the other providers'. One Relayer
///      address serves both `sendPayloadToEvm`/`quoteEVMDeliveryPrice` and inbound
///      `receiveWormholeMessages`, so `GATEWAY_ROLE` names one address. See
///      `docs/provider-research.md#6-wormhole-core-vs-the-relayer-two-different-bindings`.
contract WormholeHubTransceiver is HubTransceiverBase {
    function initialize(
        address owner_,
        address treasury_,
        address[] calldata gateways,
        address transmitterImplementation_
    ) external initializer {
        __HubTransceiverBase_init(owner_, treasury_, gateways, transmitterImplementation_);
    }

    /// @notice No gateway granted yet.
    /// @dev No R3.3 exception needed, same conclusion as CCIP/Hyperlane: the Relayer's
    ///      callback carries `sourceAddress`/`sourceChainId` but has no enrolled-peer check of
    ///      its own before calling back. `_authenticateOrigin` is the only origin check.
}
