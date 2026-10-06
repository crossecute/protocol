// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMessageRecipient} from "@hyperlane/interfaces/IMessageRecipient.sol";

import {HyperlaneZkSyncTransceiver} from "src/protocols/hyperlane/HyperlaneDivergentTransceiver.sol";
import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {HyperlaneTransceiver} from "src/protocols/hyperlane/HyperlaneTransceiver.sol";
import {HyperlaneReceiver} from "src/protocols/hyperlane/HyperlaneReceiver.sol";
import {HyperlaneTransmitter} from "src/protocols/hyperlane/HyperlaneTransmitter.sol";

import {MockHyperlaneMailbox} from "test/protocols/hyperlane/MockHyperlaneMailbox.sol";
import {ProviderIdFixture, defaultReceiverInit} from "test/protocols/ProviderFixture.sol";

/// @notice Exposes the send seam for the shared send suite, and marks each message it handles.
contract HyperlaneTransceiverHarness is HyperlaneTransceiver {
    event InboundHandled(bytes32 chainKey);

    constructor(address mailbox_) HyperlaneTransceiver(mailbox_) {}

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

/// @notice Exposes the report seam.
contract HyperlaneZkSyncHarness is HyperlaneZkSyncTransceiver {
    constructor(address mailbox_) HyperlaneZkSyncTransceiver(mailbox_) {}

    function reportPublic(bytes32 home, address owner, bytes32 salt, address receiver) external {
        _reportReceiver(home, owner, salt, receiver);
    }
}

/// @notice `Mailbox.process` asserts nothing about the source-chain sender: the Mailbox's
///         gateway role admits the call, and the binding's own check refuses a wrong sender.
abstract contract HyperlaneFixture is ProviderIdFixture {
    uint32 internal constant BASE_DOMAIN = 8453;

    MockHyperlaneMailbox internal mailbox = new MockHyperlaneMailbox();

    function _transceiverImplementation() internal override returns (address) {
        return address(new HyperlaneTransceiverHarness(address(mailbox)));
    }

    function _receiverImplementation() internal override returns (address) {
        return address(new HyperlaneReceiver(address(mailbox)));
    }

    function _transmitterImplementation() internal override returns (address) {
        return address(new HyperlaneTransmitter(address(mailbox)));
    }

    function _initialize(TransceiverConfig memory c, uint256 homeId) internal pure override returns (bytes memory) {
        return abi.encodeCall(HyperlaneTransceiver.initialize, (c, uint32(homeId)));
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
        return address(mailbox);
    }

    function _remoteProviderId() internal pure override returns (uint256) {
        return BASE_DOMAIN;
    }

    function _setProviderId(address t, bytes32 chainKey, uint256 providerId) internal override {
        HyperlaneTransceiver(payable(t)).setDomain(chainKey, uint32(providerId));
    }

    function _configureRemote(address t, address) internal override {
        _setRemoteProviderId(t);
    }

    function _deliver(address to, uint256 originId, bytes32 sender, bytes memory message) internal override {
        vm.prank(address(mailbox));
        IMessageRecipient(to).handle(uint32(originId), sender, message);
    }

    function _deliverBypassingGateway(address to, bytes32 sender, bytes memory message) internal override {
        IMessageRecipient(to).handle(BASE_DOMAIN, sender, message);
    }

    function _setProviderFee(uint256 fee) internal override {
        mailbox.setFee(fee);
    }

    function _expectedQuoteFor(uint256 providerFee) internal pure override returns (uint256) {
        return providerFee;
    }
}
