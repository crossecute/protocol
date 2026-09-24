// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";

import {WormholeHubTransceiver} from "src/protocols/wormhole/WormholeHubTransceiver.sol";
import {WormholeSpokeTransceiver} from "src/protocols/wormhole/WormholeSpokeTransceiver.sol";
import {WormholeReceiver} from "src/protocols/wormhole/WormholeReceiver.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";

import {MockWormholeRelayer} from "test/protocols/wormhole/MockWormholeRelayer.sol";
import {ProviderHubSendSpec, IHubSendHarness, ProviderReceiveSpec} from "test/protocols/ProviderBindingSpec.t.sol";

/// @notice Exposes `_sendMessage`/`_quoteMessage` directly (bootstrap/ownership machinery is
///         covered by `test/Transport.t.sol`).
contract WormholeHubHarness is WormholeHubTransceiver {
    constructor(address relayer) WormholeHubTransceiver(relayer) {}

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

function _toWormholeFormat(address a) pure returns (bytes32) {
    return bytes32(uint256(uint160(a)));
}

contract WormholeSendTest is ProviderHubSendSpec {
    MockWormholeRelayer relayer;
    WormholeHubHarness hub;
    address msig = address(0x5165);
    uint16 constant BASE_WORMHOLE_CHAIN = 30;

    function setUp() public {
        relayer = new MockWormholeRelayer();
        hub = WormholeHubHarness(
            address(
                new ERC1967Proxy(
                    address(new WormholeHubHarness(address(relayer))),
                    abi.encodeCall(
                        WormholeHubTransceiver.initialize, (msig, address(0), new address[](0), address(0xBEEF))
                    )
                )
            )
        );
        harness = IHubSendHarness(address(hub));

        vm.prank(msig);
        hub.setWormholeChain(ChainKey.forEvm(8453), BASE_WORMHOLE_CHAIN);
    }

    function _configuredRecipient() internal pure override returns (bytes memory) {
        return Erc7930.encodeEvm(8453, address(0xC0DE));
    }

    function _unconfiguredRecipient() internal pure override returns (bytes memory) {
        return Erc7930.encodeEvm(1, address(0xC0DE));
    }

    function _setProviderFee(uint256 fee) internal override {
        relayer.setFee(fee);
    }

    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(relayer.sentLength(), 1);
        assertEq(relayer.sent(0).targetChain, BASE_WORMHOLE_CHAIN);
    }

    function _gasLimitAttribute(uint256 gasLimit) internal view returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(hub.WORMHOLE_GAS_LIMIT_ATTRIBUTE(), gasLimit);
    }

    function test_sendTargetsTheRecipientWithNoReceiverValue() public {
        hub.sendMessagePublic(_configuredRecipient(), "payload", new bytes[](0), 0);
        MockWormholeRelayer.Sent memory s = relayer.sent(0);
        assertEq(s.targetAddress, address(0xC0DE));
        assertEq(s.payload, "payload");
        assertEq(s.receiverValue, 0);
    }

    function test_unusedDestinationGasIsRefundedToTheRecipientOnTheTargetChain() public {
        hub.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        assertEq(relayer.sent(0).refundChain, BASE_WORMHOLE_CHAIN);
        assertEq(relayer.sent(0).refundAddress, address(0xC0DE));
    }

    function test_gasLimitDefaultsAndFollowsTheAttribute() public {
        hub.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        hub.sendMessagePublic(_configuredRecipient(), "x", _gasLimitAttribute(750_000), 0);
        assertEq(relayer.sent(0).gasLimit, WormholeMessage.DEFAULT_GAS_LIMIT);
        assertEq(relayer.sent(1).gasLimit, 750_000);
    }

    /// @dev The Relayer reverts `InvalidMsgValue` on anything but its exact quote, so without
    ///      the pay-quote-and-refund step an overpaid send reverts.
    function test_overpaymentPaysTheQuoteAndRefundsTheCaller() public {
        relayer.setFee(0.01 ether);
        address payer = address(0xFEE);
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        hub.sendMessagePublic{value: 0.03 ether}(_configuredRecipient(), "x", new bytes[](0), 0.03 ether);
        assertEq(relayer.sent(0).value, 0.01 ether);
        assertEq(payer.balance, 0.99 ether);
        assertEq(address(hub).balance, 0);
    }

    function test_underpaymentIsRefused() public {
        relayer.setFee(0.01 ether);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(WormholeMessage.InsufficientWormholeValue.selector, 0.005 ether, 0.01 ether)
        );
        hub.sendMessagePublic{value: 0.005 ether}(_configuredRecipient(), "x", new bytes[](0), 0.005 ether);
    }

    function test_unknownAttributeIsRefused() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(bytes4(0xdeadbeef), uint256(1));
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.UnknownWormholeAttribute.selector, attrs[0]));
        hub.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_nonEvmWidthRecipientIsRefused() public {
        bytes memory wide = abi.encodePacked(bytes32(uint256(0xC0DE)));
        bytes memory recipient = Erc7930.encode(Erc7930.CT_EIP155, Erc7930.minimalBigEndian(8453), wide);
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.UnsupportedWormholeRecipient.selector, wide));
        hub.sendMessagePublic(recipient, "x", new bytes[](0), 0);
    }
}

/// @notice The Relayer authenticates the delivery VAA, not the source-chain sender, so
///         `isSourceTransmitter` inside `receiveWormholeMessages` is the only sender check.
contract WormholeReceiveTest is ProviderReceiveSpec {
    MockWormholeRelayer relayer;
    WormholeReceiver receiver;
    address sourceTransmitter = address(0xABCD);

    function setUp() public {
        relayer = new MockWormholeRelayer();
        receiver = WormholeReceiver(
            payable(address(
                    new ERC1967Proxy(
                        address(new WormholeReceiver(address(relayer))),
                        abi.encodeCall(WormholeReceiver.initialize, (sourceTransmitter, new Call[](0)))
                    )
                ))
        );
    }

    function _deliver(bytes32 sender, bytes memory payload, bytes[] memory additional) internal {
        receiver.receiveWormholeMessages(payload, additional, sender, 2, bytes32(0));
    }

    function _receiverUnderTest() internal view override returns (address) {
        return address(receiver);
    }

    function _deliverFromConfiguredSource() internal override {
        vm.prank(address(relayer));
        _deliver(_toWormholeFormat(sourceTransmitter), Payload.encodeCalls(new Call[](0)), new bytes[](0));
    }

    function _deliverFromImpersonator() internal override {
        vm.prank(address(relayer));
        _deliver(_toWormholeFormat(address(0xBAD)), "", new bytes[](0));
    }

    /// @dev `WormholeReceiver` keeps no origin state (same as `CcipReceiver`), so the
    ///      unconfigured-origin case is the impersonator case.
    function _deliverFromUnconfiguredOrigin() internal override {
        vm.prank(address(relayer));
        _deliver(_toWormholeFormat(address(0xBAD)), "", new bytes[](0));
    }

    function _deliverFromWrongCaller() internal override {
        _deliver(_toWormholeFormat(sourceTransmitter), "", new bytes[](0));
    }

    function test_additionalMessagesAreRejected() public {
        bytes[] memory additional = new bytes[](1);
        vm.prank(address(relayer));
        vm.expectRevert(WormholeMessage.AdditionalMessagesNotSupported.selector);
        _deliver(_toWormholeFormat(sourceTransmitter), Payload.encodeCalls(new Call[](0)), additional);
    }

    /// @dev High bits set: must not be truncated into an address that happens to match.
    function test_senderWiderThan20BytesIsRejected() public {
        bytes32 wide = bytes32(uint256(uint160(sourceTransmitter)) | (uint256(1) << 200));
        vm.prank(address(relayer));
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.UnsupportedWormholeSender.selector, wide));
        _deliver(wide, "", new bytes[](0));
    }

    function test_receiverGrantsTheRelayerTheGatewayRole() public view {
        assertTrue(receiver.hasRole(receiver.GATEWAY_ROLE(), address(relayer)));
    }
}

contract WormholeTransceiverReceiveTest is Test {
    MockWormholeRelayer relayer;
    WormholeSpokeTransceiver spoke;
    WormholeHubTransceiver hub;
    uint16 constant HOME_WORMHOLE_CHAIN = 2;
    address homeTransceiver = address(0xD00D);

    function setUp() public {
        relayer = new MockWormholeRelayer();
        spoke = WormholeSpokeTransceiver(
            address(new ERC1967Proxy(address(new WormholeSpokeTransceiver(address(relayer))), _spokeInit(2)))
        );
        hub = WormholeHubTransceiver(
            address(
                new ERC1967Proxy(
                    address(new WormholeHubTransceiver(address(relayer))),
                    abi.encodeCall(
                        WormholeHubTransceiver.initialize,
                        (address(this), address(0), new address[](0), address(0xBEEF))
                    )
                )
            )
        );
    }

    function _spokeInit(uint16 homeWormholeChain) internal view returns (bytes memory) {
        return abi.encodeCall(
            WormholeSpokeTransceiver.initialize,
            (
                new address[](0),
                address(0xC0DE),
                ChainKey.forEvm(1),
                Erc7930.encodeEvmChain(1),
                abi.encodePacked(homeTransceiver),
                homeWormholeChain
            )
        );
    }

    function test_hubAndSpokeGrantTheRelayerTheGatewayRole() public view {
        assertTrue(hub.hasRole(hub.GATEWAY_ROLE(), address(relayer)));
        assertTrue(spoke.hasRole(spoke.GATEWAY_ROLE(), address(relayer)));
    }

    function test_spokeRejectsZeroHomeWormholeChain() public {
        address impl = address(new WormholeSpokeTransceiver(address(relayer)));
        vm.expectRevert(WormholeSpokeTransceiver.ZeroHomeWormholeChain.selector);
        new ERC1967Proxy(impl, _spokeInit(0));
    }

    /// @dev The hub's own address, delivered from any chain but home, is not the hub.
    function test_spokeRejectsTheHubsAddressFromAnotherChain() public {
        vm.prank(address(relayer));
        vm.expectRevert(abi.encodeWithSelector(WormholeSpokeTransceiver.UnexpectedSourceChain.selector, 5));
        spoke.receiveWormholeMessages("", new bytes[](0), _toWormholeFormat(homeTransceiver), 5, bytes32(0));
    }

    function test_spokeRejectsANonHubSenderFromHome() public {
        vm.prank(address(relayer));
        vm.expectRevert();
        spoke.receiveWormholeMessages(
            "", new bytes[](0), _toWormholeFormat(address(0xBAD)), HOME_WORMHOLE_CHAIN, bytes32(0)
        );
    }

    function test_spokeRejectsAdditionalMessages() public {
        vm.prank(address(relayer));
        vm.expectRevert(WormholeMessage.AdditionalMessagesNotSupported.selector);
        spoke.receiveWormholeMessages(
            "", new bytes[](1), _toWormholeFormat(homeTransceiver), HOME_WORMHOLE_CHAIN, bytes32(0)
        );
    }

    function test_spokeRejectsAnyCallerButTheRelayer() public {
        vm.expectRevert();
        spoke.receiveWormholeMessages(
            "", new bytes[](0), _toWormholeFormat(homeTransceiver), HOME_WORMHOLE_CHAIN, bytes32(0)
        );
    }

    function test_hubRejectsAnUnmappedSourceChain() public {
        vm.prank(address(relayer));
        vm.expectRevert(abi.encodeWithSelector(ProviderChainId.UnknownProviderId.selector, uint256(999)));
        hub.receiveWormholeMessages("", new bytes[](0), _toWormholeFormat(address(0xC0DE)), 999, bytes32(0));
    }

    function test_hubRejectsAnyCallerButTheRelayer() public {
        vm.expectRevert();
        hub.receiveWormholeMessages("", new bytes[](0), _toWormholeFormat(address(0xC0DE)), 2, bytes32(0));
    }
}
