// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CcipReceiver} from "src/protocols/ccip/CcipReceiver.sol";
import {GasAttribute} from "script/deploy/GasAttribute.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {CcipZkSyncTransceiver, CcipTronTransceiver} from "src/protocols/ccip/CcipDivergentTransceiver.sol";
import {TronTransceiverExtension} from "src/messaging/transceiver/DivergentTransceiver.sol";
import {
    TransceiverDeployment,
    transceiverExtension,
    zkSyncTransceiverExtension
} from "script/deploy/TransceiverDeploy.sol";
import {CcipDeploy} from "script/deploy/CcipDeploy.sol";
import {CcipTransceiver} from "src/protocols/ccip/CcipTransceiver.sol";

import {MockCcipRouter} from "test/protocols/ccip/MockCcipRouter.sol";
import {ProviderGasFixture, defaultReceiverInit} from "test/protocols/ProviderFixture.sol";
import {Call} from "src/messaging/Call.sol";

/// @notice Exposes the send seam for the shared send suite, and marks each message it handles.
contract CcipTransceiverHarness is CcipTransceiver {
    event InboundHandled(bytes32 chainKey);

    constructor(address router_) CcipTransceiver(router_, transceiverExtension()) {}

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

function ccipMessage(uint64 selector, bytes32 sender, bytes memory data) pure returns (Client.Any2EVMMessage memory) {
    return Client.Any2EVMMessage({
        messageId: bytes32(0),
        sourceChainSelector: selector,
        sender: abi.encode(sender),
        data: data,
        destTokenAmounts: new Client.EVMTokenAmount[](0)
    });
}

/// @notice Exposes the report seam.
contract CcipTronHarness is CcipTronTransceiver {
    constructor(address gateway) CcipTronTransceiver(gateway, address(new TronTransceiverExtension())) {}

    function reportPublic(bytes32 home, address owner, bytes32 salt, address receiver) external {
        _reportReceiver(home, owner, salt, receiver);
    }
}

/// @notice Exposes the report seam.
contract CcipZkSyncHarness is CcipZkSyncTransceiver {
    constructor(address router_) CcipZkSyncTransceiver(router_, zkSyncTransceiverExtension()) {}

    function reportPublic(bytes32 home, address owner, bytes32 salt, address receiver) external {
        _reportReceiver(home, owner, salt, receiver);
    }
}

/// @notice CCIP's off-ramp asserts nothing about the sender: the router's gateway role admits
///         the call, and the binding's own check refuses a wrong sender.
abstract contract CcipFixture is ProviderGasFixture {
    uint64 internal constant BASE_SELECTOR = 15_971_525_489_660_198_786;

    MockCcipRouter internal router = new MockCcipRouter();

    /// @notice The router every implementation is built with and the gateway it is granted.
    function _ccipRouter() internal view virtual returns (address) {
        return address(router);
    }

    function _transceiverImplementation() internal override returns (address) {
        return address(new CcipTransceiverHarness(_ccipRouter()));
    }

    function _receiverImplementation() internal override returns (address) {
        return CcipDeploy.receiverImplementation(_ccipRouter());
    }

    function _signedReceiverImplementation(address guard, address multiSendCallOnly)
        internal
        override
        returns (address)
    {
        return address(new CcipReceiver(_ccipRouter(), guard, multiSendCallOnly));
    }

    function _transmitterImplementation() internal override returns (address) {
        return CcipDeploy.transmitterImplementation(_ccipRouter());
    }

    function _deploy(TransceiverDeployment memory d, uint256 homeId) internal override returns (address) {
        return CcipDeploy.transceiver(d, _ccipRouter(), uint64(homeId));
    }

    function _attributes() internal pure override returns (bytes[] memory) {
        return new bytes[](0);
    }

    function _gateway() internal view override returns (address) {
        return _ccipRouter();
    }

    function _remoteProviderId() internal pure override returns (uint256) {
        return BASE_SELECTOR;
    }

    function _setProviderId(address t, bytes32 chainKey, uint256 providerId) internal override {
        CcipTransceiver(payable(t)).setSelector(chainKey, uint64(providerId));
    }

    function _configureRemote(address t, address) internal override {
        _setRemoteProviderId(t);
    }

    function _deliver(address to, uint256 originId, bytes32 sender, bytes memory message) internal override {
        vm.prank(address(router));
        IAny2EVMMessageReceiver(to).ccipReceive(ccipMessage(uint64(originId), sender, message));
    }

    function _deliverBypassingGateway(address to, bytes32 sender, bytes memory message) internal override {
        IAny2EVMMessageReceiver(to).ccipReceive(ccipMessage(BASE_SELECTOR, sender, message));
    }

    function _setProviderFee(uint256 fee) internal override {
        router.setFee(fee);
    }

    function _expectedQuoteFor(uint256 providerFee) internal pure override returns (uint256) {
        return providerFee;
    }

    function _initializeReceiver(address sourceTransmitter, Call[] memory calls)
        internal
        pure
        override
        returns (bytes memory)
    {
        return defaultReceiverInit(sourceTransmitter, _remoteProviderId(), calls);
    }

    /// @dev `GenericExtraArgsV2` after its 4-byte tag; the gas limit is its first word.
    function _lastGasLimit() internal view override returns (uint256) {
        return _uintAt(router.sent(router.sentLength() - 1).extraArgs, 4, 32);
    }

    function _gasAttribute(uint256 gas) internal pure override returns (bytes memory) {
        return GasAttribute.ccip(gas);
    }
}
