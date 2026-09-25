// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";

import {OpStackHubTransceiver} from "src/protocols/op-stack/OpStackHubTransceiver.sol";
import {OpStackSpokeTransceiver} from "src/protocols/op-stack/OpStackSpokeTransceiver.sol";
import {OpStackReceiver} from "src/protocols/op-stack/OpStackReceiver.sol";
import {OpStackMessage, IOpStackRecipient} from "src/protocols/op-stack/OpStackMessage.sol";

import {MockCrossDomainMessenger} from "test/protocols/op-stack/MockCrossDomainMessenger.sol";
import {ProviderHubSendSpec, IHubSendHarness, ProviderReceiveSpec} from "test/protocols/ProviderBindingSpec.t.sol";

/// @notice Exposes `_sendMessage`/`_quoteMessage` directly (bootstrap/ownership machinery is
///         covered by `test/Transport.t.sol`).
contract OpStackHubHarness is OpStackHubTransceiver {
    constructor(address messenger, bytes32 chainKey) OpStackHubTransceiver(messenger, chainKey) {}

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
}

contract OpStackSendTest is ProviderHubSendSpec {
    MockCrossDomainMessenger messenger;
    OpStackHubHarness hub;
    uint256 constant BASE = 8453;

    function setUp() public {
        messenger = new MockCrossDomainMessenger();
        hub = OpStackHubHarness(
            address(
                new ERC1967Proxy(
                    address(new OpStackHubHarness(address(messenger), ChainKey.forEvm(BASE))),
                    abi.encodeCall(
                        OpStackHubTransceiver.initialize,
                        (address(0x5165), address(0), new address[](0), address(0xBEEF))
                    )
                )
            )
        );
        harness = IHubSendHarness(address(hub));
    }

    function _configuredRecipient() internal pure override returns (bytes memory) {
        return Erc7930.encodeEvm(BASE, address(0xC0DE));
    }

    /// @dev Any chain but the messenger's: the destination is which messenger is called.
    function _unconfiguredRecipient() internal pure override returns (bytes memory) {
        return Erc7930.encodeEvm(10, address(0xC0DE));
    }

    /// @dev No provider fee to set: deposits pay in burned gas, not `msg.value`.
    function _setProviderFee(uint256) internal override {}

    function _expectedQuoteFor(uint256) internal pure override returns (uint256) {
        return 0;
    }

    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(messenger.sentLength(), 1);
        assertEq(messenger.sent(0).sender, address(hub));
        assertEq(messenger.sent(0).target, address(0xC0DE));
    }

    function test_messageIsTheEntryPointCallWithThePayload() public {
        hub.sendMessagePublic(_configuredRecipient(), "payload", new bytes[](0), 0);
        assertEq(messenger.sent(0).message, abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, (bytes("payload"))));
        assertEq(messenger.sent(0).value, 0);
    }

    function test_minGasLimitDefaultsAndFollowsTheAttribute() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(hub.OP_STACK_MIN_GAS_LIMIT_ATTRIBUTE(), uint256(900_000));
        hub.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        hub.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
        assertEq(messenger.sent(0).minGasLimit, OpStackMessage.DEFAULT_MIN_GAS_LIMIT);
        assertEq(messenger.sent(1).minGasLimit, 900_000);
    }

    /// @dev `msg.value` on `sendMessage` is bridged to the target, not spent as a fee.
    function test_nonzeroValueIsRefused() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(OpStackMessage.OpStackValueNotSupported.selector, 1));
        hub.sendMessagePublic{value: 1}(_configuredRecipient(), "x", new bytes[](0), 1);
    }

    /// @dev A recipient on another chain must not be delivered through this messenger, which
    ///      would land it at the same address on this messenger's chain.
    function test_aRecipientOnAnotherChainIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                OpStackMessage.NotThisMessengersChain.selector, ChainKey.forEvm(10), ChainKey.forEvm(BASE)
            )
        );
        hub.sendMessagePublic(Erc7930.encodeEvm(10, address(0xC0DE)), "x", new bytes[](0), 0);
    }

    function test_quoteRevertsWhereTheSendWould() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                OpStackMessage.NotThisMessengersChain.selector, ChainKey.forEvm(10), ChainKey.forEvm(BASE)
            )
        );
        hub.quoteMessagePublic(Erc7930.encodeEvm(10, address(0xC0DE)), "x");
    }

    /// @dev A malformed first attribute is reported even when an extra follows it.
    function test_malformedFirstAttributeIsReportedBeforeAnExtra() public {
        bytes[] memory attrs = new bytes[](2);
        attrs[0] = abi.encodePacked(bytes4(0xdeadbeef), uint256(1));
        attrs[1] = abi.encodePacked(hub.OP_STACK_MIN_GAS_LIMIT_ATTRIBUTE(), uint256(1));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        hub.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_minGasLimitAboveUint32IsRefused() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(hub.OP_STACK_MIN_GAS_LIMIT_ATTRIBUTE(), uint256(type(uint32).max) + 1);
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        hub.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_nonEvmWidthRecipientIsRefused() public {
        bytes memory wide = abi.encodePacked(bytes32(uint256(0xC0DE)));
        bytes memory recipient = Erc7930.encode(Erc7930.CT_EIP155, Erc7930.minimalBigEndian(BASE), wide);
        vm.expectRevert(abi.encodeWithSelector(OpStackMessage.UnsupportedOpStackRecipient.selector, wide));
        hub.sendMessagePublic(recipient, "x", new bytes[](0), 0);
    }
}

/// @notice The sharp edge: the sender is `xDomainMessageSender()`, never anything in the
///         delivered calldata, which the origin-side caller wrote in full.
contract OpStackReceiveTest is ProviderReceiveSpec {
    MockCrossDomainMessenger messenger;
    OpStackReceiver receiver;
    address sourceTransmitter = address(0xABCD);

    function setUp() public {
        messenger = new MockCrossDomainMessenger();
        receiver = OpStackReceiver(
            payable(address(
                    new ERC1967Proxy(
                        address(new OpStackReceiver(address(messenger))),
                        abi.encodeCall(OpStackReceiver.initialize, (sourceTransmitter, new Call[](0)))
                    )
                ))
        );
    }

    function _entry(bytes memory payload) internal pure returns (bytes memory) {
        return abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, (payload));
    }

    function _receiverUnderTest() internal view override returns (address) {
        return address(receiver);
    }

    function _gateway() internal view override returns (address) {
        return address(messenger);
    }

    function _deliverFromConfiguredSource() internal override {
        messenger.relay(sourceTransmitter, address(receiver), _entry(Payload.encodeCalls(new Call[](0))));
    }

    function _deliverFromImpersonator() internal override {
        messenger.relay(address(0xBAD), address(receiver), _entry(Payload.encodeCalls(new Call[](0))));
    }

    /// @dev An OP Stack messenger relays only from its one paired chain, so there is no other
    ///      origin to configure; the unconfigured-origin case is the impersonator case.
    function _deliverFromUnconfiguredOrigin() internal override {
        messenger.relay(address(0xBAD), address(receiver), _entry(Payload.encodeCalls(new Call[](0))));
    }

    function _deliverFromWrongCaller() internal override {
        receiver.receiveOpStackMessage(Payload.encodeCalls(new Call[](0)));
    }

    /// @dev `sendMessage` is permissionless: an attacker can put the transmitter's address
    ///      anywhere in the message they send. Only `xDomainMessageSender()` counts.
    function test_aSenderClaimedInsideTheMessageIsIgnored() public {
        bytes memory claimed = abi.encodePacked(
            abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, (Payload.encodeCalls(new Call[](0)))),
            abi.encode(sourceTransmitter)
        );
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        messenger.relay(address(0xBAD), address(receiver), claimed);
    }

    /// @dev Outside a relay, `xDomainMessageSender()` reverts; a gateway calling in directly
    ///      cannot supply a sender either.
    function test_theMessengerCallingOutsideARelayIsRejected() public {
        vm.prank(address(messenger));
        vm.expectRevert("CrossDomainMessenger: xDomainMessageSender is not set");
        receiver.receiveOpStackMessage(Payload.encodeCalls(new Call[](0)));
    }

    function test_receiverGrantsTheMessengerTheGatewayRole() public view {
        assertTrue(receiver.hasRole(receiver.GATEWAY_ROLE(), address(messenger)));
    }
}

contract OpStackTransceiverReceiveTest is Test {
    MockCrossDomainMessenger messenger;
    OpStackSpokeTransceiver spoke;
    OpStackHubTransceiver hub;
    address homeTransceiver = address(0xD00D);

    function setUp() public {
        messenger = new MockCrossDomainMessenger();
        spoke = OpStackSpokeTransceiver(
            address(
                new ERC1967Proxy(
                    address(new OpStackSpokeTransceiver(address(messenger))),
                    abi.encodeCall(
                        OpStackSpokeTransceiver.initialize,
                        (
                            new address[](0),
                            address(0xC0DE),
                            ChainKey.forEvm(1),
                            Erc7930.encodeEvmChain(1),
                            abi.encodePacked(homeTransceiver)
                        )
                    )
                )
            )
        );
        hub = OpStackHubTransceiver(
            address(
                new ERC1967Proxy(
                    address(new OpStackHubTransceiver(address(messenger), ChainKey.forEvm(8453))),
                    abi.encodeCall(
                        OpStackHubTransceiver.initialize, (address(this), address(0), new address[](0), address(0xBEEF))
                    )
                )
            )
        );
    }

    function test_hubAndSpokeGrantTheMessengerTheGatewayRole() public view {
        assertTrue(hub.hasRole(hub.GATEWAY_ROLE(), address(messenger)));
        assertTrue(spoke.hasRole(spoke.GATEWAY_ROLE(), address(messenger)));
    }

    function test_spokeRejectsANonHubSender() public {
        vm.expectRevert();
        messenger.relay(address(0xBAD), address(spoke), abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, ("")));
    }

    function test_spokeRejectsAnyCallerButTheMessenger() public {
        vm.expectRevert();
        spoke.receiveOpStackMessage("");
    }

    /// @dev The hub's only origin is the messenger's chain; with no route recorded for it,
    ///      nothing is accepted.
    function test_hubRejectsDeliveryBeforeItsChainIsRouted() public {
        vm.expectRevert();
        messenger.relay(address(0xC0DE), address(hub), abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, ("")));
    }

    function test_hubRejectsAnyCallerButTheMessenger() public {
        vm.expectRevert();
        hub.receiveOpStackMessage("");
    }
}
