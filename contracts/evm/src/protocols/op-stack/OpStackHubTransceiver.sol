// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";

/// @notice The transceiver on the home chain, for ONE OP Stack destination.
///
/// @dev ONE INSTANCE PER ROLLUP, NOT ONE FOR THE STACK, AND THAT IS STRUCTURAL HERE RATHER
///      THAN A DEPLOYMENT PREFERENCE. `ICrossDomainMessenger.sendMessage(target, message,
///      minGasLimit)` names no destination chain: each OP Stack chain has its own dedicated
///      `L1CrossDomainMessenger` at its own L1 address, and the destination IS which
///      messenger you call. So [`ProviderChainId`](../ProviderChainId.sol), the chain-id
///      table every other native binding needs, DOES NOT APPLY to this one: this contract
///      holds one messenger address as its own immutable, and reaching a second OP Stack
///      chain means deploying a second `OpStackHubTransceiver`, not adding a row to a table.
///      See `docs/provider-research.md#7-op-stack-as-a-native-binding`.
///
/// @dev IT CARRIES NO PROVIDER VOCABULARY AT ALL, AND THAT IS WHAT ERC-7786 BOUGHT, EXACTLY
///      AS ON THE OTHER TEMPLATES. A gateway takes a recipient that NAMES ITS OWN CHAIN, so
///      there is nothing to translate and the route slot holds that chain's ERC-7930
///      identifier.
///
/// @dev Does NOT inherit a transmitter, for the same reason as every other binding: a
///      transceiver is shared infrastructure the msig administers and a transmitter is
///      per-user, owned by its user.
///
/// @dev ONE MESSENGER ADDRESS SERVES BOTH DIRECTIONS. `sendMessage` (send) and the contract
///      that calls this transceiver's inbound entry point via `relayMessage` (receive) are
///      the same `ICrossDomainMessenger` deployment, so `GATEWAY_ROLE` names one address
///      here, not two.
///
/// @dev NO ON-CHAIN QUOTE. There is no `quote`-shaped function on `ICrossDomainMessenger`;
///      `_quoteMessage` falls back to the off-chain measurement in R2.2.2, the same escape
///      hatch already used for bare Wormhole Core.
contract OpStackHubTransceiver is HubTransceiverBase {
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
    /// @dev That is the honest state of a binding with no OP Stack behind it. A real binding
    ///      grants `GATEWAY_ROLE` to the `L1CrossDomainMessenger` for this specific rollup in
    ///      the initializer, which is where the address is known; the absence fails loudly on
    ///      the first message rather than quietly on a forged one.
    ///
    /// @dev THIS IS THE HUB SIDE, WHICH RARELY RECEIVES AT ALL. The return leg only fires
    ///      where `addressesDiverge`, which is false for an OP Stack chain running standard
    ///      `op-geth` CREATE2 arithmetic; see `OpStackSpokeTransceiver`. Where this DOES
    ///      receive (a diverging deployment choice this template does not assume), see
    ///      `OpStackReceiver`'s note on why the authenticated sender must come from
    ///      `xDomainMessageSender()` rather than from the message's own calldata.

}
