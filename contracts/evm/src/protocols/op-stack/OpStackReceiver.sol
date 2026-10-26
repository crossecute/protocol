// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {OpStackMessage, IOpStackRecipient} from "src/protocols/op-stack/OpStackMessage.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice The initializer an `op-stack-l1-l2` receiver is armed with: its home's messenger
///         on this chain, which a transceiver on Ethereum holds one of per OP Stack chain.
interface IOpStackReceiverInit {
    function initialize(address sourceTransmitter, Call[] calldata calls, address messenger) external;
}

/// @notice Per-user conduit on a non-home chain, for `op-stack-l1-l2`.
/// @dev The origin is the messenger that called, the one granted `GATEWAY_ROLE`, which relays
///      only from the conduit's home.
contract OpStackReceiver is ReceiverBase, IOpStackRecipient, IOpStackReceiverInit {
    /// @dev Refused, not just unused: it would arm the conduit with no gateway.
    error UseOpStackInitializer();

    function initialize(address, bytes32, Call[] calldata) external pure override {
        revert UseOpStackInitializer();
    }

    /// @dev `_grantInitialRole` is `onlyInitializing`, so this initializer is the only window the
    ///      messenger's gateway grant ever gets.
    function initialize(address sourceTransmitter_, Call[] calldata calls, address messenger)
        external
        override
        initializer
    {
        if (messenger == address(0)) revert ProviderAddress.ZeroEndpoint();
        _grantInitialRole(GATEWAY_ROLE, messenger);
        __ReceiverBase_init(sourceTransmitter_, bytes32(uint256(uint160(messenger))), calls);
    }

    /// @dev The sender is `xDomainMessageSender()`, never anything in `payload`: see
    ///      `OpStackMessage.sender`. No R3.3 exception; `_onMessageFrom` is the only
    ///      sender check.
    function receiveOpStackMessage(bytes calldata payload) external override onlyRole(GATEWAY_ROLE) {
        _onMessageFrom(bytes32(uint256(uint160(msg.sender))), OpStackMessage.sender(), payload);
    }
}
