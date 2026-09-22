// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";

/// @notice Per-user account on a non-home chain.
/// @dev No gateway granted yet. The Relayer's callback shape differs from `receiveMessage`,
///      so a real binding implements `IWormholeReceiver.receiveWormholeMessages(payload,
///      additionalMessages, sourceAddress, sourceChainId, deliveryHash)` directly, gated
///      `onlyRole(GATEWAY_ROLE)`, and translates into `_authenticateSender`+`_onMessage`.
///      `sourceAddress` is a raw `bytes32` needing narrowing first. `additionalMessages`
///      (batched VAAs, e.g. CCTP) is unused — require empty.
///
/// @dev No replay guard needed: this targets the Relayer, whose `deliveryAttempted` dedupes
///      the same way LZ/CCIP/Hyperlane do. A bare-Core binding would need to track consumed
///      messages itself. See
///      `docs/provider-research.md#6-wormhole-core-vs-the-relayer-two-different-bindings`.
contract WormholeReceiver is ReceiverBase {}
