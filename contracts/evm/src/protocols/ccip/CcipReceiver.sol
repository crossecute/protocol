// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";

/// @notice The per-user account on every chain that is not the home chain.
///
/// @dev NO GATEWAY IS GRANTED, so this receiver accepts nothing, which is the honest state of
///      a binding with no CCIP behind it. A real binding grants `GATEWAY_ROLE` to the CCIP
///      Router from its own `initialize`, before calling `__ReceiverBase_init`. `grantRole`
///      is `onlyInitializing`, so that is the only moment a gateway can be named.
///
/// @dev THE NAME `CcipReceiver` COLLIDES IN SPIRIT, NOT IN CODE, WITH CHAINLINK'S OWN
///      `CCIPReceiver`. A real binding is not expected to inherit Chainlink's base contract
///      here: `CCIPReceiver.ccipReceive` is gated on `onlyRouter`
///      (`msg.sender == i_ccipRouter`), which duplicates exactly what this repo's own
///      `GATEWAY_ROLE` check on `receiveMessage` already does, at the cost of a second
///      transport-identity fact to keep in sync with the one `Roles` already tracks. The
///      cleaner shape is to implement `IAny2EVMMessageReceiver.ccipReceive` directly, gated
///      by `onlyRole(GATEWAY_ROLE)` alone, and translate `Client.Any2EVMMessage` into a call
///      to this contract's own `_authenticateSender` and `_onMessage` (`InboundBase`'s pair,
///      which `receiveMessage` already composes for the ERC-7786 path): `message.sender` is
///      `abi.encode`d, not a raw 20-byte slice, so it needs `abi.decode(message.sender,
///      (address))` before `_authenticateSender` sees it. See
///      `docs/provider-research.md#4-ccip-as-a-native-binding`.
contract CcipReceiver is ReceiverBase {}
