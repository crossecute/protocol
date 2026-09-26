// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {OpStackMessage, IOpStackRecipient} from "src/protocols/op-stack/OpStackMessage.sol";

/// @notice Per-user account on a non-home chain.
/// @dev No origin-chain check: an OP Stack messenger relays only from its one paired chain.
contract OpStackReceiver is ReceiverBase, IOpStackRecipient {
    /// @notice This chain's `CrossDomainMessenger`. Set on the implementation; safe because
    ///         the implementation address lives in the proxy's ERC-1967 slot, not its initcode,
    ///         so this never moves a derived account address.
    address public immutable messenger;

    constructor(address messenger_) {
        messenger = messenger_;
    }

    /// @dev `grantRole` is `onlyInitializing`, so this initializer is the only window the
    ///      messenger's gateway grant ever gets.
    function initialize(address sourceTransmitter_, Call[] calldata calls) external override initializer {
        grantRole(GATEWAY_ROLE, messenger);
        __ReceiverBase_init(sourceTransmitter_, calls);
    }

    /// @dev The sender is `xDomainMessageSender()`, never anything in `payload`: see
    ///      `OpStackMessage.sender`. No R3.3 exception; `_onMessageFrom` is the only
    ///      sender check.
    function receiveOpStackMessage(bytes calldata payload) external override onlyRole(GATEWAY_ROLE) {
        _onMessageFrom(OpStackMessage.sender(), payload);
    }
}
