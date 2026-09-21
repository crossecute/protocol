// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";

/// @notice The per-user account on every chain that is not the home chain.
///
/// @dev NO GATEWAY IS GRANTED, so this receiver accepts nothing, which is the honest state of
///      a binding with no OP Stack behind it. A real binding grants `GATEWAY_ROLE` to the
///      local `CrossDomainMessenger` (the L2 predeploy, a constant address on every OP Stack
///      chain) from its own `initialize`, before calling `__ReceiverBase_init`. `grantRole`
///      is `onlyInitializing`, so that is the only moment a gateway can be named.
///
/// @dev THE SHARP EDGE, AND IT MUST NOT BE GOTTEN WRONG: `relayMessage` calls this contract
///      with calldata that WHOEVER CALLED `sendMessage` on the origin domain wrote in full,
///      since `sendMessage` is permissionless. Nothing about that calldata's own bytes is
///      trustworthy. The only fact the protocol actually guarantees is retrieved separately,
///      by calling `xDomainMessageSender()` on `msg.sender` (the messenger itself) DURING
///      this execution. A real binding's entry point:
///
///        1. is gated `onlyRole(GATEWAY_ROLE)`, same as every other binding;
///        2. calls `ICrossDomainMessenger(msg.sender).xDomainMessageSender()` itself, and
///           treats THAT as the origin — never a "sender" argument decoded out of its own
///           payload, which would let anyone impersonate this account's transmitter simply
///           by claiming to be it in calldata they wrote themselves;
///        3. hands that address to `_authenticateSender` (`InboundBase`'s seam, which
///           `receiveMessage` already composes with `_onMessage` for the ERC-7786 path).
///
///      This is not a variant of the LayerZero/CCIP/Hyperlane/Wormhole shape with different
///      argument names: those four each have the transport compute and pass the origin as a
///      value into the callback. OP Stack does not, and treating it as if it did would be a
///      real vulnerability, not a style mismatch. See
///      `docs/provider-research.md#7-op-stack-as-a-native-binding`.
contract OpStackReceiver is ReceiverBase {}
