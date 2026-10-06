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
    ProviderSendSpec,
    ProviderReceiveSpec,
    ProviderEvmRecipientSpec,
    ProviderTransmitterSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {OpStackFixture} from "test/protocols/op-stack/OpStackFixture.sol";

/// @notice The destination is which messenger is called, so the check is that this one was,
///         addressed to the recipient.
contract OpStackTransceiverSendTest is ProviderSendSpec, ProviderEvmRecipientSpec, OpStackFixture {
    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(messenger.sentLength(), 1);
        assertEq(messenger.sent(0).sender, address(harness));
        assertEq(messenger.sent(0).target, REMOTE_COUNTERPART);
    }

    function _supportedAttribute() internal pure override returns (bytes memory) {
        return abi.encodePacked(OpStackMessage.MIN_GAS_LIMIT_ATTRIBUTE, uint256(1));
    }

    function test_messageIsTheEntryPointCallWithThePayload() public {
        harness.sendMessagePublic(_configuredRecipient(), "payload", new bytes[](0), 0);
        assertEq(messenger.sent(0).message, abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, (bytes("payload"))));
        assertEq(messenger.sent(0).value, 0);
    }

    function test_minGasLimitDefaultsAndFollowsTheAttribute() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(OpStackMessage.MIN_GAS_LIMIT_ATTRIBUTE, uint256(900_000));
        harness.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        harness.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
        assertEq(messenger.sent(0).minGasLimit, OpStackMessage.DEFAULT_MIN_GAS_LIMIT);
        assertEq(messenger.sent(1).minGasLimit, 900_000);
    }

    /// @dev Value handed to the messenger is bridged to the target, not spent as a fee.
    function test_nonzeroValueIsRefused() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(OpStackMessage.OpStackValueNotSupported.selector, 1));
        harness.sendMessagePublic{value: 1}(_configuredRecipient(), "x", new bytes[](0), 1);
    }

    /// @dev A recipient on another chain must not be delivered through this messenger, which
    ///      would land it at the same address on this messenger's chain.
    function test_aRecipientOnAnotherChainIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                OpStackMessage.NotThisMessengersChain.selector, ChainKey.forEvm(10), ChainKey.forEvm(REMOTE_CHAIN_ID)
            )
        );
        harness.sendMessagePublic(Erc7930.encodeEvm(10, address(0xC0DE)), "x", new bytes[](0), 0);
    }

    function test_quoteRevertsForAnotherMessengersChain() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                OpStackMessage.NotThisMessengersChain.selector, ChainKey.forEvm(10), ChainKey.forEvm(REMOTE_CHAIN_ID)
            )
        );
        harness.quoteMessagePublic(Erc7930.encodeEvm(10, address(0xC0DE)), "x");
    }

    function test_minGasLimitAboveUint32IsRefused() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(OpStackMessage.MIN_GAS_LIMIT_ATTRIBUTE, uint256(type(uint32).max) + 1);
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        harness.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }
}

/// @notice The sharp edge: the sender is `xDomainMessageSender()`, never anything in the
///         delivered calldata, which the origin-side caller wrote in full. A messenger relays
///         only from its one paired chain, so the unconfigured-origin case is the impersonator
///         case.
contract OpStackReceiveTest is ProviderReceiveSpec, OpStackFixture {
    /// @dev `sendMessage` is permissionless: an attacker can put the transmitter's address
    ///      anywhere in the message they send. Only `xDomainMessageSender()` counts.
    function test_aSenderClaimedInsideTheMessageIsIgnored() public {
        bytes memory claimed = abi.encodePacked(
            abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, (Payload.encodeCalls(new Call[](0)))),
            abi.encode(SOURCE_TRANSMITTER)
        );
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        messenger.relay(address(0xBAD), receiver, claimed);
    }

    /// @dev Outside a relay, `xDomainMessageSender()` reverts; a gateway calling in directly
    ///      cannot supply a sender either.
    function test_theMessengerCallingOutsideARelayIsRejected() public {
        vm.prank(address(messenger));
        vm.expectRevert("CrossDomainMessenger: xDomainMessageSender is not set");
        OpStackReceiver(payable(receiver)).receiveOpStackMessage(Payload.encodeCalls(new Call[](0)));
    }
}

contract OpStackTransmitterInboundTest is ProviderTransmitterSpec, OpStackFixture {}
