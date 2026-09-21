// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";

/// @notice The per-user account on every chain that is not the home chain.
///
/// @dev NO GATEWAY IS GRANTED, so this receiver accepts nothing, which is the honest state of
///      a binding with no Wormhole behind it. A real binding grants `GATEWAY_ROLE` to the
///      Wormhole Relayer contract from its own `initialize`, before calling
///      `__ReceiverBase_init`. `grantRole` is `onlyInitializing`, so that is the only moment
///      a gateway can be named.
///
/// @dev THE RELAYER'S CALLBACK HAS A DIFFERENT SHAPE THAN `receiveMessage`, so a real binding
///      does not implement `IERC7786Recipient` here at all: it implements
///      `IWormholeReceiver.receiveWormholeMessages(payload, additionalMessages, sourceAddress,
///      sourceChainId, deliveryHash)` directly, gated by `onlyRole(GATEWAY_ROLE)`, and
///      translates into a call to this contract's own `_authenticateSender` and `_onMessage`
///      (`InboundBase`'s pair, which `receiveMessage` already composes for the ERC-7786 path).
///      `sourceAddress` arrives as a raw `bytes32`, Wormhole's own address width, and needs
///      narrowing before `_authenticateSender` sees it, the same shape as Hyperlane's
///      `bytes32` sender. `additionalMessages` is for batched VAAs (e.g. CCTP transfers) this
///      protocol does not use and a binding should require empty.
///
/// @dev NO REPLAY GUARD NEEDED HERE, BECAUSE THIS TARGETS THE RELAYER, NOT BARE CORE. The
///      Relayer's own `deliveryAttempted(deliveryHash)` dedupes the way LayerZero's, CCIP's,
///      and Hyperlane's transports already do. A bare-Core binding would be the one place in
///      this protocol that has to track consumed messages itself; see the research note.
contract WormholeReceiver is ReceiverBase {}
