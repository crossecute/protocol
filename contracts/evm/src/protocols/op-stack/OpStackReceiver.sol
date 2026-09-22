// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";

/// @notice Per-user account on a non-home chain.
/// @dev No gateway granted yet. A real binding grants `GATEWAY_ROLE` to the local
///      `CrossDomainMessenger` (the L2 predeploy, constant address on every OP Stack chain).
///
/// @dev SHARP EDGE: `relayMessage` calls this contract with calldata whoever called
///      `sendMessage` on the origin domain wrote in full — `sendMessage` is permissionless,
///      so nothing in that calldata is trustworthy. The authenticated sender MUST come from
///      calling `ICrossDomainMessenger(msg.sender).xDomainMessageSender()`, never from a
///      value decoded out of the payload — a self-declared sender there would let anyone
///      impersonate this account's transmitter. Unlike LayerZero/CCIP/Hyperlane/Wormhole,
///      the transport does not compute and pass the origin for you. See
///      `docs/provider-research.md#7-op-stack-as-a-native-binding`.
contract OpStackReceiver is ReceiverBase {}
