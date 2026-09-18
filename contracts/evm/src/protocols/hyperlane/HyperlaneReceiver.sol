// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";

/// @notice The per-user account on every chain that is not the home chain.
///
/// @dev NO GATEWAY IS GRANTED, so this receiver accepts nothing, which is the honest state of
///      a binding with no Hyperlane behind it. A real binding grants `GATEWAY_ROLE` to the
///      Hyperlane Mailbox from its own `initialize`, before calling `__ReceiverBase_init`.
///      `grantRole` is `onlyInitializing`, so that is the only moment a gateway can be named.
///
/// @dev THIS CONTRACT MUST NOT INHERIT `MailboxClient` OR `Router`, HYPERLANE'S OWN CLIENT
///      BASE CONTRACTS. Both pull in `OwnableUpgradeable` from OpenZeppelin 4.9.3
///      (`MailboxClient._MailboxClient_initialize` calls the zero-argument
///      `__Ownable_init()`, which is 4.x's signature), and this repo is pinned to OZ 5.4.0,
///      whose `OwnableUpgradeable` has no zero-argument initializer at all. Mixing the two
///      does not compile. See `docs/provider-research.md#5-hyperlane-as-a-native-binding`.
///
/// @dev THE RIGHT SHAPE IS TO SKIP `Router` TOO, EVEN ASIDE FROM THE VERSION COLLISION.
///      `Router.handle` checks an enrolled-router-per-domain mapping (`_routers`) BEFORE
///      calling into the app's own `_handle`, which is the same shape this repo already
///      rejected for OpenZeppelin's `CrosschainLinked`: "its own gateway allowlist would
///      replace the shared-transceiver routing and bypass the registry's provenance dial"
///      (`docs/provider-research.md#3-erc-7786-as-a-transport`). A real binding implements
///      `IMessageRecipient.handle(uint32 origin, bytes32 sender, bytes calldata message)`
///      directly, gated by `onlyRole(GATEWAY_ROLE)` alone, and holds the `IMailbox` address
///      as its own immutable rather than inheriting anything that carries one. `sender` is a
///      raw `bytes32`; `TypeCasts.bytes32ToAddress` (a pure, dependency-free library, safe to
///      vendor on its own) narrows it before `_authenticateSender` sees it.
contract HyperlaneReceiver is ReceiverBase {}
