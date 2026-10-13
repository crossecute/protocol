// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {OpStackInteropMessage} from "src/protocols/op-stack/OpStackInteropMessage.sol";
import {IOpStackRecipient} from "src/protocols/op-stack/OpStackMessage.sol";

/// @notice Per-user account on a non-home chain, for `op-stack-l2-l2`.
/// @dev The origin is the source chain id the messenger reports, which must be the home's.
contract OpStackInteropReceiver is ReceiverBase, IOpStackRecipient {
    /// @dev `grantRole` is `onlyInitializing`, so this initializer is the only window the
    ///      messenger's gateway grant ever gets.
    function initialize(address sourceTransmitter_, bytes32 homeOrigin_, Call[] calldata calls)
        external
        override
        initializer
    {
        grantRole(GATEWAY_ROLE, OpStackInteropMessage.MESSENGER);
        __ReceiverBase_init(sourceTransmitter_, homeOrigin_, calls);
    }

    /// @dev The sender is `crossDomainMessageSender()`, never anything in `payload`. No R3.3
    ///      exception; `_onMessageFrom` is the only sender check.
    function receiveOpStackMessage(bytes calldata payload) external override onlyRole(GATEWAY_ROLE) {
        (address sender, uint256 source) = OpStackInteropMessage.context();
        _onMessageFrom(bytes32(source), sender, payload);
    }
}
