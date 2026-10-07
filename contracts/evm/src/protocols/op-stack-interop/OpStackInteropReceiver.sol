// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {
    OpStackInteropMessage,
    IOpStackInteropRecipient
} from "src/protocols/op-stack-interop/OpStackInteropMessage.sol";

/// @notice Per-user account on a non-home chain, for `op-stack-l2-l2`.
/// @dev No origin-chain check, as on every receiver here: the sender must be the account's
///      own transmitter, whose address on any other chain in the dependency set is this
///      account's receiver, driven by the same owner.
contract OpStackInteropReceiver is ReceiverBase, IOpStackInteropRecipient {
    /// @dev `grantRole` is `onlyInitializing`, so this initializer is the only window the
    ///      messenger's gateway grant ever gets.
    function initialize(address sourceTransmitter_, Call[] calldata calls) external override initializer {
        grantRole(GATEWAY_ROLE, OpStackInteropMessage.MESSENGER);
        __ReceiverBase_init(sourceTransmitter_, calls);
    }

    /// @dev The sender is `crossDomainMessageSender()`, never anything in `payload`. No R3.3
    ///      exception; `_onMessageFrom` is the only sender check.
    function receiveInteropMessage(bytes calldata payload) external override onlyRole(GATEWAY_ROLE) {
        (address sender,) = OpStackInteropMessage.context();
        _onMessageFrom(sender, payload);
    }
}
