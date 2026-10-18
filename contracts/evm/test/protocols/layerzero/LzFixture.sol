// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";

import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {LzDeploy} from "script/deploy/LzDeploy.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {LzTransceiver} from "src/protocols/layerzero/LzTransceiver.sol";
import {LzZkSyncTransceiver} from "src/protocols/layerzero/LzDivergentTransceiver.sol";
import {ILzReceiverInit} from "src/protocols/layerzero/LzReceiver.sol";

import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {unseeded} from "test/RegistrySeed.sol";

import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";
import {ProviderGasFixture} from "test/protocols/ProviderFixture.sol";
import {toBytes32} from "test/Harness.sol";
import {LzMessage} from "src/protocols/layerzero/LzMessage.sol";

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

    function quoteMessagePublic(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        external
        view
        returns (uint256)
    {
        return _quoteMessage(recipient, payload, attributes);
    }

    function _handleInbound(bytes32 origin, bytes calldata message) internal override {
        emit InboundHandled(origin);
        super._handleInbound(origin, message);
    }
}

/// @notice Exposes the report seam.
contract LzZkSyncHarness is LzZkSyncTransceiver {
    constructor(address endpoint_) LzZkSyncTransceiver(endpoint_) {}

    function reportPublic(bytes32 home, address owner, bytes32 salt, address receiver) external {
        _reportReceiver(home, owner, salt, receiver);
    }
}

/// @notice LayerZero delivers only from an eid's set peer, checked inside OApp before this
///         protocol's code runs, so configuring a remote chain sets its peer as well as its eid.
abstract contract LzFixture is ProviderGasFixture {
    uint32 internal constant BASE_EID = 30184;

    MockLzEndpoint internal endpoint = new MockLzEndpoint();

    function _transceiverImplementation() internal override returns (address) {
        return address(new LzTransceiverHarness(address(endpoint)));
    }

    function _receiverImplementation() internal override returns (address) {
        return LzDeploy.receiverImplementation(address(endpoint));
    }

    function _transmitterImplementation() internal override returns (address) {
        return LzDeploy.transmitterImplementation(address(endpoint));
    }

    function _deploy(TransceiverDeployment memory d, uint256 homeId) internal override returns (address) {
        return LzDeploy.transceiver(d, uint32(homeId), address(0));
    }

    /// @dev A receiver's peer is its transmitter on the account's home.
    function _initializeReceiver(address sourceTransmitter, Call[] memory calls)
        internal
        pure
        override
        returns (bytes memory)
    {
        return abi.encodeCall(ILzReceiverInit.initialize, (sourceTransmitter, calls, BASE_EID, address(0)));
    }

    function _attributes() internal pure override returns (bytes[] memory) {
        return new bytes[](0);
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

    /// @dev The peer must be the counterpart (#62), so a transceiver with no registry, as the
    ///      send suite's is, gets one that records `counterpart` on a `Unique` remote chain.
    function _configureRemote(address t, address counterpart) internal override {
        _setRemoteProviderId(t);
        TransceiverBase tb = TransceiverBase(payable(t));
        if (address(tb.chainRegistry()) == address(0)) {
            ChainRegistry registry = new ChainRegistry(address(this), unseeded());
            bytes32 provider = registry.addMessageProvider("under-test");
            bytes32 remote = registry.addChainKey(Erc7930.encodeEvmChain(REMOTE_CHAIN_ID), Provenance.Unique);
            vm.startPrank(tb.owner());
            tb.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Unique);
            tb.setCounterpart(remote, Erc7930.encodeEvm(REMOTE_CHAIN_ID, counterpart));
            vm.stopPrank();
        }
        vm.prank(tb.owner());
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

    /// @dev Type-3 options with one `lzReceive` option, whose gas is bytes 6 to 22.
    function _lastGasLimit() internal view override returns (uint256) {
        return _uintAt(endpoint.sent(endpoint.sentLength() - 1).options, 6, 16);
    }

    function _gasAttribute(uint256 gas) internal pure override returns (bytes memory) {
        return abi.encodePacked(LzMessage.OPTIONS_ATTRIBUTE, uint16(3), uint8(1), uint16(17), uint8(1), uint128(gas));
    }
}
