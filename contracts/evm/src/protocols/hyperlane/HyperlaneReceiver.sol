// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";

/// @notice Per-user account on a non-home chain.
/// @dev No gateway granted yet. Must not inherit `MailboxClient`/`Router`: both pin
///      OpenZeppelin 4.9.3's zero-arg `__Ownable_init()`, incompatible with this repo's 5.4.0
///      (see `HyperlaneTransmitter`). `Router` is also skipped on its own merits — its
///      enrolled-router-per-domain check runs before the app's own `_handle`, the same shape
///      already rejected for OZ's `CrosschainLinked` (bypasses the registry's provenance
///      dial). A real binding implements `IMessageRecipient.handle(uint32, bytes32, bytes)`
///      directly, gated `onlyRole(GATEWAY_ROLE)`, holds `IMailbox` as its own immutable, and
///      narrows the raw `bytes32` sender via `TypeCasts.bytes32ToAddress` before
///      `_authenticateSender` sees it. See
///      `docs/provider-research.md#5-hyperlane-as-a-native-binding`.
contract HyperlaneReceiver is ReceiverBase {}
