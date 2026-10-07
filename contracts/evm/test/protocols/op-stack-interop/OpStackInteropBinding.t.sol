// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {
    OpStackInteropMessage,
    IOpStackInteropRecipient
} from "src/protocols/op-stack-interop/OpStackInteropMessage.sol";

import {
    ProviderSendSpec,
    ProviderReceiveSpec,
    ProviderEvmRecipientSpec,
    ProviderTransmitterSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {OpStackInteropFixture} from "test/protocols/op-stack-interop/OpStackInteropFixture.sol";

/// @notice The destination is the recipient's chain id, handed to the one messenger.
contract OpStackInteropTransceiverSendTest is ProviderSendSpec, ProviderEvmRecipientSpec, OpStackInteropFixture {
    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(MESSENGER.sentLength(), 1);
        assertEq(MESSENGER.sent(0).destination, REMOTE_CHAIN_ID);
        assertEq(MESSENGER.sent(0).target, REMOTE_COUNTERPART);
        assertEq(MESSENGER.sent(0).sender, address(harness));
    }

    /// @dev The binding supports none, so any well-formed attribute stands in.
    function _supportedAttribute() internal pure override returns (bytes memory) {
        return abi.encodePacked(bytes4(keccak256("crossecute.test.any")), uint256(1));
    }

    function test_messageIsTheEntryPointCallWithThePayload() public {
        harness.sendMessagePublic(_configuredRecipient(), "payload", new bytes[](0), 0);
        assertEq(
            MESSENGER.sent(0).message,
            abi.encodeCall(IOpStackInteropRecipient.receiveInteropMessage, (bytes("payload")))
        );
    }

    /// @dev `sendMessage` is not payable, so value can only be refused.
    function test_nonzeroValueIsRefused() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(OpStackInteropMessage.InteropValueNotSupported.selector, 1));
        harness.sendMessagePublic{value: 1}(_configuredRecipient(), "x", new bytes[](0), 1);
    }

    /// @dev Even under a route to this chain, which nothing refuses at `setRoute`. The messenger
    ///      refuses it too; refusing first keeps the quote in step with the send.
    function test_aSendToThisChainIsRefused() public {
        address owner = TransceiverBase(payable(address(harness))).owner();
        vm.prank(owner);
        TransceiverBase(payable(address(harness))).setRoute(ChainKey.local(), Erc7930.encodeEvmChain(block.chainid));
        bytes memory here = Erc7930.encodeEvm(block.chainid, REMOTE_COUNTERPART);
        vm.expectRevert(OpStackInteropMessage.InteropToThisChain.selector);
        harness.sendMessagePublic(here, "x", new bytes[](0), 0);
        vm.expectRevert(OpStackInteropMessage.InteropToThisChain.selector);
        harness.quoteMessagePublic(here, "x");
    }
}

/// @notice The sender is `crossDomainMessageSender()`, never anything in the delivered calldata.
///         The receiver keeps no origin state, so the unconfigured-origin case is the
///         impersonator case.
contract OpStackInteropReceiveTest is ProviderReceiveSpec, OpStackInteropFixture {
    function test_aSenderClaimedInsideTheMessageIsIgnored() public {
        bytes memory claimed = abi.encodePacked(
            abi.encodeCall(IOpStackInteropRecipient.receiveInteropMessage, (Payload.encodeCalls(new Call[](0)))),
            abi.encode(SOURCE_TRANSMITTER)
        );
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        MESSENGER.relay(REMOTE_CHAIN_ID, address(0xBAD), receiver, claimed);
    }

    /// @dev Outside a relay the messenger has no context, so a call from it cannot name a sender.
    function test_theMessengerCallingOutsideARelayIsRejected() public {
        vm.prank(address(MESSENGER));
        vm.expectRevert();
        IOpStackInteropRecipient(receiver).receiveInteropMessage(Payload.encodeCalls(new Call[](0)));
    }
}

contract OpStackInteropTransmitterInboundTest is ProviderTransmitterSpec, OpStackInteropFixture {}
