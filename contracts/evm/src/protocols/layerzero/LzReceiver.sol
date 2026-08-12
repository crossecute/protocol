// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";

/// @notice The per-user account on every chain that is not the home chain.
///
/// @dev NO GATEWAY IS GRANTED, so this receiver accepts nothing, which is the honest state of
///      a binding with no LayerZero behind it. A real binding grants `GATEWAY_ROLE` to its
///      endpoint from its own `initialize`, before calling `__ReceiverBase_init` — the account
///      holds no `ADMIN`, so initialization is the only moment a gateway can be named.
contract LzReceiver is ReceiverBase {}
