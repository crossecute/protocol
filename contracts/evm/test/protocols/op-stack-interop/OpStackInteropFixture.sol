// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {OpStackInteropDeploy} from "script/deploy/OpStackInteropDeploy.sol";
import {Call} from "src/messaging/Call.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {OpStackInteropTransceiver} from "src/protocols/op-stack-interop/OpStackInteropTransceiver.sol";
import {
    OpStackInteropMessage,
    IOpStackInteropRecipient
} from "src/protocols/op-stack-interop/OpStackInteropMessage.sol";

import {MockL2ToL2CrossDomainMessenger} from "test/protocols/op-stack-interop/MockL2ToL2CrossDomainMessenger.sol";
import {ProviderFixture, defaultReceiverInit} from "test/protocols/ProviderFixture.sol";

/// @notice Exposes the send seam for the shared send suite, and marks each message it handles.
contract OpStackInteropTransceiverHarness is OpStackInteropTransceiver {
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

/// @notice The messenger is the predeploy, so the mock sits at its address. A chain is named by
///         its chain id, and nothing is configured per chain but its route.
abstract contract OpStackInteropFixture is ProviderFixture {
    MockL2ToL2CrossDomainMessenger internal constant MESSENGER =
        MockL2ToL2CrossDomainMessenger(OpStackInteropMessage.MESSENGER);

    constructor() {
        deployCodeTo("MockL2ToL2CrossDomainMessenger.sol:MockL2ToL2CrossDomainMessenger", address(MESSENGER));
    }

    function _transceiverImplementation() internal override returns (address) {
        return address(new OpStackInteropTransceiverHarness());
    }

    function _receiverImplementation() internal override returns (address) {
        return OpStackInteropDeploy.receiverImplementation();
    }

    function _transmitterImplementation() internal override returns (address) {
        return OpStackInteropDeploy.transmitterImplementation();
    }

    function _deploy(TransceiverDeployment memory d, uint256) internal override returns (address) {
        return OpStackInteropDeploy.transceiver(d);
    }

    function _initializeReceiver(address sourceTransmitter, Call[] memory calls)
        internal
        pure
        override
        returns (bytes memory)
    {
        return defaultReceiverInit(sourceTransmitter, calls);
    }

    function _gateway() internal pure override returns (address) {
        return address(MESSENGER);
    }

    /// @dev Interop names a chain by its chain id.
    function _remoteProviderId() internal pure override returns (uint256) {
        return REMOTE_CHAIN_ID;
    }

    /// @dev With no id table, the route is the configuration a send needs.
    function _configureRemote(address t, address) internal override {
        address owner = TransceiverBase(payable(t)).owner();
        vm.prank(owner);
        TransceiverBase(payable(t)).setRoute(ChainKey.forEvm(REMOTE_CHAIN_ID), Erc7930.encodeEvmChain(REMOTE_CHAIN_ID));
    }

    /// @dev The messenger reports a 20-byte sender, so a wider one cannot be expressed.
    function _deliver(address to, uint256 originId, bytes32 sender, bytes memory message) internal override {
        require(uint256(sender) >> 160 == 0, "interop senders are addresses");
        MESSENGER.relay(
            originId,
            address(uint160(uint256(sender))),
            to,
            abi.encodeCall(IOpStackInteropRecipient.receiveInteropMessage, (message))
        );
    }

    function _deliverBypassingGateway(address to, bytes32, bytes memory message) internal override {
        IOpStackInteropRecipient(to).receiveInteropMessage(message);
    }

    /// @dev `sendMessage` is not payable; the relay pays for itself.
    function _setProviderFee(uint256) internal override {}

    function _expectedQuoteFor(uint256) internal pure override returns (uint256) {
        return 0;
    }
}
