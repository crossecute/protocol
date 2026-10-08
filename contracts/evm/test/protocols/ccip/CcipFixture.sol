// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAny2EVMMessageReceiver} from "@ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@ccip/libraries/Client.sol";

import {CcipZkSyncTransceiver} from "src/protocols/ccip/CcipDivergentTransceiver.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {CcipDeploy} from "script/deploy/CcipDeploy.sol";
import {CcipTransceiver} from "src/protocols/ccip/CcipTransceiver.sol";

import {MockCcipRouter} from "test/protocols/ccip/MockCcipRouter.sol";
import {ProviderGasFixture, defaultReceiverInit} from "test/protocols/ProviderFixture.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
import {Call} from "src/messaging/Call.sol";

/// @notice Exposes the send seam for the shared send suite, and marks each message it handles.
contract CcipTransceiverHarness is CcipTransceiver {
    event InboundHandled(bytes32 chainKey);

    constructor(address router_) CcipTransceiver(router_) {}

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
contract CcipZkSyncHarness is CcipZkSyncTransceiver {
    constructor(address router_) CcipZkSyncTransceiver(router_) {}

    function reportPublic(bytes32 home, address owner, bytes32 salt, address receiver) external {
        _reportReceiver(home, owner, salt, receiver);
    }
}

/// @notice CCIP's off-ramp asserts nothing about the sender: the router's gateway role admits
///         the call, and the binding's own check refuses a wrong sender.
abstract contract CcipFixture is ProviderGasFixture {
    uint64 internal constant BASE_SELECTOR = 15_971_525_489_660_198_786;

    MockCcipRouter internal router = new MockCcipRouter();

    function _transceiverImplementation() internal override returns (address) {
        return address(new CcipTransceiverHarness(address(router)));
    }

    function _receiverImplementation() internal override returns (address) {
        return CcipDeploy.receiverImplementation(address(router));
    }

    function _transmitterImplementation() internal override returns (address) {
        return CcipDeploy.transmitterImplementation(address(router));
    }

    function _deploy(TransceiverDeployment memory d, uint256 homeId) internal override returns (address) {
        return CcipDeploy.transceiver(d, address(router), uint64(homeId));
    }

    function _gateway() internal view override returns (address) {
        return address(router);
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
        return defaultReceiverInit(sourceTransmitter, calls);
    }

    /// @dev `EVMExtraArgsV2` after its 4-byte tag; the gas limit is its first word.
    function _lastGasLimit() internal view override returns (uint256) {
        (,,,, bytes memory extraArgs,) = router.sent(router.sentLength() - 1);
        return _uintAt(extraArgs, 4, 32);
    }

    function _gasAttribute(uint256 gas) internal pure override returns (bytes memory) {
        return abi.encodePacked(CcipMessage.EXTRA_ARGS_ATTRIBUTE, abi.encode(gas, false));
    }
}
