// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";

/// @notice Transceiver on the home chain, for ONE OP Stack destination.
/// @dev `sendMessage(target, message, minGasLimit)` names no destination chain — each OP
///      Stack chain has its own dedicated `L1CrossDomainMessenger`, so the destination IS
///      which messenger you call. `ProviderChainId` does not apply here; this contract holds
///      one messenger address as its own immutable, and reaching a second chain means
///      deploying a second `OpStackHubTransceiver`.
///
/// @dev THIS IS A TRUST-DOMAIN CHOICE, NOT AN INTERFACE LIMITATION. A `chainKey => messenger
///      address` table would let one instance reach every OP Stack chain — nothing in
///      `sendMessage` forbids it. The reason not to: `messageProvider`/
///      `minCounterpartProvenance` describe ONE trust level for everything an instance
///      reaches, accurate for LZ/CCIP/Hyperlane/Wormhole (one validator/DVN/guardian/relayer
///      network secures every destination) but NOT here — Optimism's and Base's canonical
///      bridges are independent security systems that happen to run the same stack software.
///      One instance reaching both would make one provenance dial describe two things that
///      fail independently. Cost: N deployments, N `setProvenance` entries, N routes instead
///      of one. See `provider-research.md` §2.
///
/// @dev One messenger address serves both directions (`sendMessage` and the caller of
///      `relayMessage`), so `GATEWAY_ROLE` names one address.
///
/// @dev No on-chain quote: `ICrossDomainMessenger` has no `quote`-shaped function.
///      `_quoteMessage` falls back to the off-chain measurement in R2.2.2.
contract OpStackHubTransceiver is HubTransceiverBase {
    function initialize(
        address owner_,
        address treasury_,
        address[] calldata gateways,
        address transmitterImplementation_
    ) external initializer {
        __HubTransceiverBase_init(owner_, treasury_, gateways, transmitterImplementation_);
    }

    /// @notice No gateway granted yet. A real binding grants `GATEWAY_ROLE` to the
    ///         `L1CrossDomainMessenger` for this rollup in the initializer.
    /// @dev The hub side rarely receives (the return leg only fires where
    ///      `addressesDiverge`, false for standard `op-geth` CREATE2). Where it does, see
    ///      `OpStackReceiver`'s note on `xDomainMessageSender()`.
}
