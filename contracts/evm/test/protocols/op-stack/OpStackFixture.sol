// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {OpStackDeploy} from "script/deploy/OpStackDeploy.sol";
import {Call} from "src/messaging/Call.sol";
import {OpStackTransceiver} from "src/protocols/op-stack/OpStackTransceiver.sol";
import {IOpStackRecipient, OpStackMessage} from "src/protocols/op-stack/OpStackMessage.sol";
import {IOpStackReceiverInit} from "src/protocols/op-stack/OpStackReceiver.sol";

import {MockCrossDomainMessenger} from "test/protocols/op-stack/MockCrossDomainMessenger.sol";
import {ProviderGasFixture} from "test/protocols/ProviderFixture.sol";

/// @notice Exposes the send seam for the shared send suite, and marks each message it handles.
contract OpStackTransceiverHarness is OpStackTransceiver {
    event InboundHandled(bytes32 chainKey);

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

/// @notice The messenger that reaches `REMOTE_CHAIN_ID` is its provider id, so the mock sits at a
///         fixed address. The sender is `xDomainMessageSender()`, never anything in the
///         delivered calldata.
abstract contract OpStackFixture is ProviderGasFixture {
    address internal constant REMOTE_MESSENGER = address(0x4E55E7);

    MockCrossDomainMessenger internal constant MESSENGER = MockCrossDomainMessenger(REMOTE_MESSENGER);

    constructor() {
        deployCodeTo("MockCrossDomainMessenger.sol:MockCrossDomainMessenger", REMOTE_MESSENGER);
    }

    function _transceiverImplementation() internal override returns (address) {
        return address(new OpStackTransceiverHarness());
    }

    function _receiverImplementation() internal override returns (address) {
        return OpStackDeploy.receiverImplementation();
    }

    function _transmitterImplementation() internal override returns (address) {
        return OpStackDeploy.transmitterImplementation();
    }

    function _deploy(TransceiverDeployment memory d, uint256 homeId) internal override returns (address) {
        return OpStackDeploy.transceiver(d, address(uint160(homeId)));
    }

    function _initializeReceiver(address sourceTransmitter, Call[] memory calls)
        internal
        pure
        override
        returns (bytes memory)
    {
        return abi.encodeCall(IOpStackReceiverInit.initialize, (sourceTransmitter, calls, REMOTE_MESSENGER));
    }

    function _gateway() internal pure override returns (address) {
        return REMOTE_MESSENGER;
    }

    function _remoteProviderId() internal pure override returns (uint256) {
        return uint160(REMOTE_MESSENGER);
    }

    function _setProviderId(address t, bytes32 chainKey, uint256 providerId) internal override {
        OpStackTransceiver(payable(t)).setMessenger(chainKey, address(uint160(providerId)));
    }

    function _configureRemote(address t, address) internal override {
        _setRemoteProviderId(t);
    }

    /// @dev Relayed by the messenger at `originId`, given the mock's code if it has none. The
    ///      messenger reports a 20-byte sender, so a wider one cannot be expressed.
    function _deliver(address to, uint256 originId, bytes32 sender, bytes memory message) internal override {
        require(uint256(sender) >> 160 == 0, "OP Stack senders are addresses");
        address from = address(uint160(originId));
        if (from.code.length == 0) vm.etch(from, REMOTE_MESSENGER.code);
        MockCrossDomainMessenger(from)
            .relay(
                address(uint160(uint256(sender))),
                to,
                abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, (message))
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

    function _lastGasLimit() internal view override returns (uint256) {
        return MESSENGER.sent(MESSENGER.sentLength() - 1).minGasLimit;
    }

    function _gasAttribute(uint256 gas) internal pure override returns (bytes memory) {
        return abi.encodePacked(OpStackMessage.MIN_GAS_LIMIT_ATTRIBUTE, gas);
    }
}
