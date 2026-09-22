// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";

/// @notice Per-user account on a non-home chain.
/// @dev No gateway granted yet. A real binding does not inherit Chainlink's `CCIPReceiver`
///      (its `onlyRouter` duplicates what `GATEWAY_ROLE` already checks); it implements
///      `IAny2EVMMessageReceiver.ccipReceive` directly, gated `onlyRole(GATEWAY_ROLE)`, and
///      translates into `_authenticateSender`+`_onMessage`. `message.sender` is
///      `abi.encode`d, not a raw 20-byte slice — decode before `_authenticateSender` sees it.
///      See `docs/provider-research.md#4-ccip-as-a-native-binding`.
contract CcipReceiver is ReceiverBase {}
