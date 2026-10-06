// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {OpStackTransceiver} from "src/protocols/op-stack/OpStackTransceiver.sol";
import {OpStackReceiver} from "src/protocols/op-stack/OpStackReceiver.sol";
import {OpStackTransmitter} from "src/protocols/op-stack/OpStackTransmitter.sol";
import {IOpStackRecipient} from "src/protocols/op-stack/OpStackMessage.sol";

import {MockCrossDomainMessenger} from "test/protocols/op-stack/MockCrossDomainMessenger.sol";
import {ProviderFixture, defaultReceiverInit} from "test/protocols/ProviderFixture.sol";

/// @notice Exposes the send seam for the shared send suite, and marks each message it handles.
contract OpStackTransceiverHarness is OpStackTransceiver {
    event InboundHandled(bytes32 chainKey);

    constructor(address messenger_, bytes32 messengerChainKey_) OpStackTransceiver(messenger_, messengerChainKey_) {}

    function sendMessagePublic(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        external
        payable
        returns (bytes32)
    {
        return _sendMessage(recipient, payload, attributes, value);
    }

    function quoteMessagePublic(bytes memory recipient, bytes memory payload) external view returns (uint256) {
        return _quoteMessage(recipient, payload, new bytes[](0));
    }

    function _handleInbound(bytes32 origin, bytes calldata message) internal override {
        emit InboundHandled(origin);
        super._handleInbound(origin, message);
    }
}

/// @notice The messenger is paired with `REMOTE_CHAIN_ID`, an implementation immutable, so
///         there is no provider id and nothing to configure. The sender is
///         `xDomainMessageSender()`, never anything in the delivered calldata.
abstract contract OpStackFixture is ProviderFixture {
    MockCrossDomainMessenger internal messenger = new MockCrossDomainMessenger();

    function _transceiverImplementation() internal override returns (address) {
        return address(new OpStackTransceiverHarness(address(messenger), ChainKey.forEvm(REMOTE_CHAIN_ID)));
    }

    function _receiverImplementation() internal override returns (address) {
        return address(new OpStackReceiver(address(messenger)));
    }

    function _transmitterImplementation() internal override returns (address) {
        return address(new OpStackTransmitter());
    }

    function _initialize(TransceiverConfig memory c, uint256) internal pure override returns (bytes memory) {
        return abi.encodeCall(OpStackTransceiver.initialize, (c));
    }

    function _initializeReceiver(address sourceTransmitter, Call[] memory calls)
        internal
        pure
        override
        returns (bytes memory)
    {
        return defaultReceiverInit(sourceTransmitter, calls);
    }

    function _gateway() internal view override returns (address) {
        return address(messenger);
    }

    function _remoteProviderId() internal pure override returns (uint256) {
        return 0;
    }

    function _configureRemote(address, address) internal override {}

    /// @dev The messenger reports a 20-byte sender, so a wider one cannot be expressed.
    function _deliver(address to, uint256, bytes32 sender, bytes memory message) internal override {
        require(uint256(sender) >> 160 == 0, "OP Stack senders are addresses");
        messenger.relay(
            address(uint160(uint256(sender))), to, abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, (message))
        );
    }

    function _deliverBypassingGateway(address to, bytes32, bytes memory message) internal override {
        IOpStackRecipient(to).receiveOpStackMessage(message);
    }

    /// @dev Deposits pay in burned gas, not `msg.value`.
    function _setProviderFee(uint256) internal override {}

    function _expectedQuoteFor(uint256) internal pure override returns (uint256) {
        return 0;
    }
}
