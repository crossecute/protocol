// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";

import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";

import {OpStackReceiver} from "src/protocols/op-stack/OpStackReceiver.sol";
import {OpStackMessage, IOpStackRecipient} from "src/protocols/op-stack/OpStackMessage.sol";

import {
    ProviderIdTableSpec,
    ProviderReceiveSpec,
    ProviderEvmRecipientSpec,
    ProviderTransmitterSpec,
    ProviderTransmitterSendSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {OpStackFixture} from "test/protocols/op-stack/OpStackFixture.sol";
import {MockCrossDomainMessenger} from "test/protocols/op-stack/MockCrossDomainMessenger.sol";
import {OpStackTransceiver} from "src/protocols/op-stack/OpStackTransceiver.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";

/// @notice The destination is which messenger is called, so the check is that the one the table
///         maps the recipient's chain to was, addressed to the recipient.
contract OpStackTransceiverSendTest is ProviderIdTableSpec, ProviderEvmRecipientSpec, OpStackFixture {
    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(MESSENGER.sentLength(), 1);
        assertEq(MESSENGER.sent(0).sender, address(harness));
        assertEq(MESSENGER.sent(0).target, REMOTE_COUNTERPART);
    }

    function _supportedAttribute() internal pure override returns (bytes memory) {
        return abi.encodePacked(OpStackMessage.MIN_GAS_LIMIT_ATTRIBUTE, uint256(1));
    }

    function test_messageIsTheEntryPointCallWithThePayload() public {
        harness.sendMessagePublic(_configuredRecipient(), "payload", new bytes[](0), 0);
        assertEq(MESSENGER.sent(0).message, abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, (bytes("payload"))));
        assertEq(MESSENGER.sent(0).value, 0);
    }

    function test_minGasLimitDefaultsAndFollowsTheAttribute() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(OpStackMessage.MIN_GAS_LIMIT_ATTRIBUTE, uint256(900_000));
        harness.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        harness.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
        assertEq(MESSENGER.sent(0).minGasLimit, OpStackMessage.DEFAULT_MIN_GAS_LIMIT);
        assertEq(MESSENGER.sent(1).minGasLimit, 900_000);
    }

    /// @dev Value handed to the messenger is bridged to the target, not spent as a fee.
    function test_nonzeroValueIsRefused() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(OpStackMessage.OpStackValueNotSupported.selector, 1));
        harness.sendMessagePublic{value: 1}(_configuredRecipient(), "x", new bytes[](0), 1);
    }

    /// @dev #41: Ethereum's transceiver reaches every OP Stack chain, each through its own
    ///      `L1CrossDomainMessenger`.
    function test_eachChainIsSentThroughItsOwnMessenger() public {
        address second = address(0x4E55E8);
        deployCodeTo("MockCrossDomainMessenger.sol:MockCrossDomainMessenger", second);
        address owner = TransceiverBase(payable(address(harness))).owner();
        vm.prank(owner);
        OpStackTransceiver(payable(address(harness))).setMessenger(ChainKey.forEvm(10), second);

        harness.sendMessagePublic(Erc7930.encodeEvm(10, REMOTE_COUNTERPART), "to 10", new bytes[](0), 0);
        harness.sendMessagePublic(_configuredRecipient(), "to the remote", new bytes[](0), 0);

        assertEq(MockCrossDomainMessenger(second).sentLength(), 1, "chain 10 through its messenger");
        assertEq(
            MockCrossDomainMessenger(second).sent(0).message,
            abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, (bytes("to 10")))
        );
        assertEq(MESSENGER.sentLength(), 1, "the remote chain through its own");
    }

    function test_minGasLimitAboveUint32IsRefused() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(OpStackMessage.MIN_GAS_LIMIT_ATTRIBUTE, uint256(type(uint32).max) + 1);
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        harness.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }
}

/// @notice The sharp edge: the sender is `xDomainMessageSender()`, never anything in the
///         delivered calldata, which the origin-side caller wrote in full. The receiver's one
///         messenger relays only from its home, so the unconfigured-origin case is the
///         impersonator case.
contract OpStackReceiveTest is ProviderReceiveSpec, OpStackFixture {
    /// @dev `sendMessage` is permissionless: an attacker can put the transmitter's address
    ///      anywhere in the message they send. Only `xDomainMessageSender()` counts.
    function test_aSenderClaimedInsideTheMessageIsIgnored() public {
        bytes memory claimed = abi.encodePacked(
            abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, (Payload.encodeCalls(new Call[](0)))),
            abi.encode(SOURCE_TRANSMITTER)
        );
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        MESSENGER.relay(address(0xBAD), receiver, claimed);
    }

    /// @dev Outside a relay, `xDomainMessageSender()` reverts; a gateway calling in directly
    ///      cannot supply a sender either.
    function test_theMessengerCallingOutsideARelayIsRejected() public {
        vm.prank(REMOTE_MESSENGER);
        vm.expectRevert("CrossDomainMessenger: xDomainMessageSender is not set");
        OpStackReceiver(payable(receiver)).receiveOpStackMessage(Payload.encodeCalls(new Call[](0)));
    }
}

contract OpStackTransmitterInboundTest is ProviderTransmitterSpec, OpStackFixture {}

contract OpStackTransmitterSendTest is ProviderTransmitterSendSpec, OpStackFixture {}
