// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";

/// @notice The transceiver on the OP Stack chain that is not the home chain.
///
/// @dev THE ENTIRE ROUTING LAYER IS THREE WRITE-ONCE VALUES: `homeChainKey`, `homeRoute()`
///      holding that chain's ERC-7930 identifier, and `homeTransceiver()` holding the hub's
///      address. No registry to read, no table to maintain, no destination to choose. Same
///      shape as `LzSpokeTransceiver`; nothing about this layer is provider-specific.
///
/// @dev THE ROUTE IS THE CHAIN IDENTIFIER. `ICrossDomainMessenger.sendMessage` needs no
///      provider-native chain id at all — see `OpStackHubTransceiver` for why
///      `ProviderChainId` does not apply to this binding — so there is nothing else to
///      translate here either.
///
/// @dev THIS IS ALWAYS THE PARITY SPOKE, AND THERE IS NO DIVERGENT VARIANT TO CHOOSE
///      INSTEAD. `LzSpokeTransceiver` has `LzZkSyncSpokeTransceiver`/`LzTronSpokeTransceiver`
///      siblings because zkSync and Tron compute CREATE2 differently from Ethereum. An OP
///      Stack chain runs standard `op-geth` and Ethereum's own formula, so it is always the
///      case `TransceiverBase.predictCrossAccount`'s default already handles, and
///      `OpStackDivergentSpokeTransceiver` would have nothing to override. See
///      `docs/provider-research.md#7-op-stack-as-a-native-binding`.
contract OpStackSpokeTransceiver is SpokeTransceiverBase {
    /// @param homeChainKey_ keccak256 of the home chain's ERC-7930 chain identifier.
    /// @param homeChainIdentifier_ That identifier itself. It is passed rather than derived
    ///        because a chainKey is a hash and cannot be reversed, and it is checked
    ///        against `homeChainKey_` so the pair cannot disagree.
    /// @param homeTransceiver_ The hub, in this chain's address format. Fixed for the life
    ///        of the contract: there is no setter, by design.
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
    /// @dev That is the honest state of a binding with no OP Stack behind it. A real binding
    ///      grants `GATEWAY_ROLE` to the L2 `CrossDomainMessenger` predeploy in the
    ///      initializer, which is a constant address on every OP Stack chain; the absence
    ///      fails loudly on the first message rather than quietly on a forged one.
    ///
    /// @dev THE SAME SHARP EDGE AS `OpStackReceiver` APPLIES HERE, FOR BOOTSTRAP. This
    ///      contract's inbound entry point must call
    ///      `ICrossDomainMessenger(msg.sender).xDomainMessageSender()` itself and treat THAT
    ///      as the authenticated origin for `_onInbound` — never a value decoded out of the
    ///      message `relayMessage` delivers, since that calldata was written in full by
    ///      whoever called `sendMessage` on L1, and `sendMessage` is permissionless.

}
