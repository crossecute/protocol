// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVaaV1Receiver} from "@wormhole-sdk/interfaces/IExecutor.sol";

import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {WormholeDeploy} from "script/deploy/WormholeDeploy.sol";
import {Call} from "src/messaging/Call.sol";
import {WormholeTransceiver} from "src/protocols/wormhole/WormholeTransceiver.sol";

import {MockWormholeCore} from "test/protocols/wormhole/MockWormholeCore.sol";
import {MockExecutor} from "test/protocols/wormhole/MockExecutor.sol";
import {ProviderGasFixture, defaultReceiverInit, toBytes32} from "test/protocols/ProviderFixture.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";

/// @dev VAA v1 with `sigCount` zeroed 66-byte signatures (the mock Core does not check them)
///      and a payload already wrapped in the binding's destination envelope.
function _vaa(uint8 sigCount, uint16 emitterChain, address emitter, uint64 sequence, bytes memory payload)
    pure
    returns (bytes memory)
{
    return _vaa(sigCount, emitterChain, toBytes32(emitter), sequence, payload);
}

function _vaa(uint8 sigCount, uint16 emitterChain, bytes32 emitter, uint64 sequence, bytes memory payload)
    pure
    returns (bytes memory)
{
    return abi.encodePacked(
        uint8(1),
        uint32(0),
        sigCount,
        new bytes(uint256(sigCount) * 66),
        uint32(1_700_000_000),
        uint32(0),
        emitterChain,
        emitter,
        sequence,
        uint8(1),
        payload
    );
}

function _envelope(uint16 targetChain, address target, bytes memory inner) pure returns (bytes memory) {
    return abi.encodePacked(targetChain, toBytes32(target), inner);
}

/// @notice Exposes the send seam for the shared send suite, and marks each message it handles.
contract WormholeTransceiverHarness is WormholeTransceiver {
    event InboundHandled(bytes32 chainKey);

    constructor(address core, address executor_) WormholeTransceiver(core, executor_) {}

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

/// @notice `executeVAAv1` is permissionless: guardian signatures (checked by Core) authenticate
///         the emitter, so there is no gateway to bypass, and the equivalent is a VAA Core
///         rejects.
abstract contract WormholeFixture is ProviderGasFixture {
    uint16 internal constant HERE_WORMHOLE_CHAIN = 2;
    uint16 internal constant BASE_WORMHOLE_CHAIN = 30;
    uint256 internal constant CORE_MESSAGE_FEE = 1 gwei;
    address internal constant QUOTER = address(0x0907);
    address internal constant PAYEE = address(0x9A7EE);

    MockWormholeCore internal core = new MockWormholeCore(HERE_WORMHOLE_CHAIN);
    MockExecutor internal executor = new MockExecutor(HERE_WORMHOLE_CHAIN);
    /// @dev The relay provider's price, a multiple of 10^8 wei: the quote states it as a base
    ///      fee in units of 10^-10 of the currency, with a zero gas price.
    uint256 internal executorFee;
    /// @dev A fresh sequence per VAA, so a second delivery is a new message, not a replay.
    uint64 internal sequence;

    function _endpoints() internal view returns (WormholeDeploy.Endpoints memory) {
        return WormholeDeploy.Endpoints(address(core), address(executor));
    }

    function _transceiverImplementation() internal override returns (address) {
        return address(new WormholeTransceiverHarness(address(core), address(executor)));
    }

    function _receiverImplementation() internal override returns (address) {
        return WormholeDeploy.receiverImplementation(_endpoints());
    }

    function _transmitterImplementation() internal override returns (address) {
        return WormholeDeploy.transmitterImplementation(_endpoints());
    }

    function _deploy(TransceiverDeployment memory d, uint256 homeId) internal override returns (address) {
        return WormholeDeploy.transceiver(d, address(core), uint16(homeId));
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
        return address(core);
    }

    function _remoteProviderId() internal pure override returns (uint256) {
        return BASE_WORMHOLE_CHAIN;
    }

    function _setProviderId(address t, bytes32 chainKey, uint256 providerId) internal override {
        WormholeTransceiver(payable(t)).setWormholeChain(chainKey, uint16(providerId));
    }

    function _configureRemote(address t, address) internal override {
        _setRemoteProviderId(t);
    }

    function _deliver(address to, uint256 originId, bytes32 sender, bytes memory message) internal override {
        IVaaV1Receiver(to)
            .executeVAAv1(_vaa(1, uint16(originId), sender, sequence++, _envelope(HERE_WORMHOLE_CHAIN, to, message)));
    }

    /// @dev Version 2, which Core rejects.
    function _deliverBypassingGateway(address to, bytes32 sender, bytes memory message) internal override {
        bytes memory vaa = _vaa(1, BASE_WORMHOLE_CHAIN, sender, sequence++, _envelope(HERE_WORMHOLE_CHAIN, to, message));
        vaa[0] = 0x02;
        IVaaV1Receiver(to).executeVAAv1(vaa);
    }

    function _setProviderFee(uint256 fee) internal override {
        executorFee = fee;
        core.setMessageFee(CORE_MESSAGE_FEE);
    }

    /// @dev Core's message fee is paid alongside the Executor's, so the quote carries both.
    function _expectedQuoteFor(uint256 providerFee) internal pure override returns (uint256) {
        return providerFee + CORE_MESSAGE_FEE;
    }

    /// @dev A gas relay instruction: type (1), then the gas limit (16).
    function _lastGasLimit() internal view override returns (uint256) {
        return _uintAt(executor.requests(executor.requestsLength() - 1).relayInstructions, 1, 16);
    }

    /// @notice A relay provider's EQ01 quote from this chain to the remote one, valid for an
    ///         hour, charging `executorFee` whatever the gas.
    function _signedQuote() internal view returns (bytes memory) {
        return _eq01(BASE_WORMHOLE_CHAIN, uint64(block.timestamp + 1 hours), uint64(executorFee / 1e8), 0, 1, 1);
    }

    function _eq01(uint16 dstChain, uint64 expiry, uint64 baseFee, uint64 dstGasPrice, uint64 srcPrice, uint64 dstPrice)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            WormholeMessage.EQ01,
            QUOTER,
            toBytes32(PAYEE),
            HERE_WORMHOLE_CHAIN,
            dstChain,
            expiry,
            baseFee,
            dstGasPrice,
            srcPrice,
            dstPrice,
            new bytes(65)
        );
    }

    function _executionAttribute(bytes memory signedQuote, uint256 gas) internal pure returns (bytes memory) {
        return abi.encodePacked(WormholeMessage.EXECUTION_ATTRIBUTE, abi.encode(signedQuote, gas));
    }

    function _gasAttribute(uint256 gas) internal view override returns (bytes memory) {
        return _executionAttribute(_signedQuote(), gas);
    }

    /// @dev Every Wormhole send carries a signed quote.
    function _attributes() internal view override returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = _gasAttribute(0);
    }
}
