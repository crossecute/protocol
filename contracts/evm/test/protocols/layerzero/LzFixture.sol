// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";

import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {LzTransceiver} from "src/protocols/layerzero/LzTransceiver.sol";
import {LzReceiver, ILzReceiverInit} from "src/protocols/layerzero/LzReceiver.sol";
import {LzTransmitter} from "src/protocols/layerzero/LzTransmitter.sol";

import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";
import {ProviderIdFixture, toBytes32} from "test/protocols/ProviderFixture.sol";

/// @notice Exposes the send seam for the shared send suite, and marks each message it handles.
contract LzTransceiverHarness is LzTransceiver {
    event InboundHandled(bytes32 chainKey);

    constructor(address endpoint) LzTransceiver(endpoint) {}

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

/// @notice LayerZero delivers only from an eid's set peer, checked inside OApp before this
///         protocol's code runs, so configuring a remote chain sets its peer as well as its eid.
abstract contract LzFixture is ProviderIdFixture {
    uint32 internal constant BASE_EID = 30184;

    MockLzEndpoint internal endpoint = new MockLzEndpoint();

    function _transceiverImplementation() internal override returns (address) {
        return address(new LzTransceiverHarness(address(endpoint)));
    }

    function _receiverImplementation() internal override returns (address) {
        return address(new LzReceiver(address(endpoint)));
    }

    function _transmitterImplementation() internal override returns (address) {
        return address(new LzTransmitter(address(endpoint)));
    }

    function _initialize(TransceiverConfig memory c, uint256 homeId) internal pure override returns (bytes memory) {
        return abi.encodeCall(LzTransceiver.initialize, (c, uint32(homeId)));
    }

    /// @dev A receiver's peer is its transmitter on the account's home.
    function _initializeReceiver(address sourceTransmitter, Call[] memory calls)
        internal
        pure
        override
        returns (bytes memory)
    {
        return abi.encodeCall(ILzReceiverInit.initialize, (sourceTransmitter, calls, BASE_EID));
    }

    function _gateway() internal view override returns (address) {
        return address(endpoint);
    }

    function _remoteProviderId() internal pure override returns (uint256) {
        return BASE_EID;
    }

    function _setProviderId(address t, bytes32 chainKey, uint256 providerId) internal override {
        LzTransceiver(payable(t)).setEid(chainKey, uint32(providerId));
    }

    function _configureRemote(address t, address counterpart) internal override {
        _setRemoteProviderId(t);
        vm.prank(TransceiverBase(payable(t)).owner());
        LzTransceiver(payable(t)).setPeer(BASE_EID, toBytes32(counterpart));
    }

    function _deliver(address to, uint256 originId, bytes32 sender, bytes memory message) internal override {
        vm.prank(address(endpoint));
        ILayerZeroReceiver(to)
            .lzReceive(
                Origin({srcEid: uint32(originId), sender: sender, nonce: 1}), bytes32(0), message, address(0), ""
            );
    }

    function _deliverBypassingGateway(address to, bytes32 sender, bytes memory message) internal override {
        ILayerZeroReceiver(to)
            .lzReceive(Origin({srcEid: BASE_EID, sender: sender, nonce: 1}), bytes32(0), message, address(0), "");
    }

    function _setProviderFee(uint256 fee) internal override {
        endpoint.setFee(fee);
    }

    function _expectedQuoteFor(uint256 providerFee) internal pure override returns (uint256) {
        return providerFee;
    }
}
