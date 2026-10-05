// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {deployAccount} from "test/DeployCrossProxy.sol";

import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";

import {IMessageRecipient} from "@hyperlane/interfaces/IMessageRecipient.sol";
import {HyperlaneReceiver} from "src/protocols/hyperlane/HyperlaneReceiver.sol";
import {TypeCasts} from "@hyperlane/libs/TypeCasts.sol";
import {StandardHookMetadata} from "@hyperlane/hooks/libs/StandardHookMetadata.sol";

import {MockHyperlaneMailbox} from "test/protocols/hyperlane/MockHyperlaneMailbox.sol";
import {
    ProviderIdTableSpec,
    ISendHarness,
    ProviderWideSenderSpec,
    ProviderEvmRecipientSpec,
    ProviderPayloadPricedSpec,
    ProviderRefundSpec,
    ProviderTransmitterSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";
import {HyperlaneTransmitter} from "src/protocols/hyperlane/HyperlaneTransmitter.sol";
import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";

interface IHyperlaneSendHarness is ISendHarness {
    function setDomain(bytes32 chainKey, uint32 domain) external;
    function handle(uint32 origin, bytes32 sender, bytes calldata message) external payable;
    function HYPERLANE_GAS_LIMIT_ATTRIBUTE() external view returns (bytes4);
}

/// @dev Run against each Hyperlane transceiver through `_deploy`.
abstract contract HyperlaneSendSuite is
    ProviderIdTableSpec,
    ProviderEvmRecipientSpec,
    ProviderPayloadPricedSpec,
    ProviderRefundSpec
{
    MockHyperlaneMailbox mailbox;
    IHyperlaneSendHarness transceiver;
    address msig;
    uint32 constant BASE_DOMAIN = 8453;

    /// @notice Deploy the transceiver under test against `mailbox`, returning it and its owner.
    function _deploy() internal virtual returns (address deployed, address owner);

    function setUp() public {
        mailbox = new MockHyperlaneMailbox();
        (address t, address owner) = _deploy();
        transceiver = IHyperlaneSendHarness(t);
        msig = owner;
        harness = ISendHarness(address(transceiver));

        vm.prank(msig);
        transceiver.setDomain(ChainKey.forEvm(8453), BASE_DOMAIN);
    }

    function _configuredRecipient() internal pure override returns (bytes memory) {
        return Erc7930.encodeEvm(8453, address(0xC0DE));
    }

    function _unconfiguredRecipient() internal pure override returns (bytes memory) {
        return Erc7930.encodeEvm(1, address(0xC0DE));
    }

    function _configuredProviderId() internal pure override returns (uint256) {
        return BASE_DOMAIN;
    }

    function _setProviderFee(uint256 fee) internal override {
        mailbox.setFee(fee);
    }

    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(mailbox.sentLength(), 1);
        assertEq(mailbox.sent(0).destinationDomain, BASE_DOMAIN);
    }

    function _gasLimitAttribute(uint256 gasLimit) internal view returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(transceiver.HYPERLANE_GAS_LIMIT_ATTRIBUTE(), gasLimit);
    }

    function test_sendUsesTheRecipientsAddressAsBytes32() public {
        transceiver.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        assertEq(mailbox.sent(0).recipientAddress, TypeCasts.addressToBytes32(address(0xC0DE)));
    }

    function test_sendForwardsThePayloadAndValueUnchanged() public {
        mailbox.setFee(0.01 ether);
        vm.deal(address(this), 1 ether);
        transceiver.sendMessagePublic{value: 0.01 ether}(_configuredRecipient(), "payload", new bytes[](0), 0.01 ether);
        assertEq(mailbox.sent(0).body, "payload");
        assertEq(mailbox.sent(0).value, 0.01 ether);
    }

    function test_hookMetadataCarriesTheGasLimitAttributeAndRefundTarget() public {
        transceiver.sendMessagePublic(_configuredRecipient(), "x", _gasLimitAttribute(400_000), 0);
        assertEq(mailbox.sent(0).metadata, StandardHookMetadata.formatMetadata(0, 400_000, address(this), ""));
    }

    function test_noAttributeMeansTheIgpDefaultGasLimit() public {
        transceiver.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        assertEq(mailbox.sent(0).metadata, StandardHookMetadata.formatMetadata(0, 50_000, address(this), ""));
    }

    /// @dev Without `refundAddress` in the metadata the refund goes to the sending contract,
    ///      and the transceiver's float would keep the payer's excess.
    function test_overpaymentIsRefundedToTheCallerNotTheTransceiver() public {
        mailbox.setFee(0.01 ether);
        address payer = address(0xFEE);
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        transceiver.sendMessagePublic{value: 0.03 ether}(_configuredRecipient(), "x", new bytes[](0), 0.03 ether);
        assertEq(payer.balance, 0.99 ether);
        assertEq(address(transceiver).balance, 0);
    }

    /// @dev A malformed first attribute is reported even when an extra follows it.
    function test_malformedFirstAttributeIsReportedBeforeAnExtra() public {
        bytes[] memory attrs = new bytes[](2);
        attrs[0] = abi.encodePacked(bytes4(0xdeadbeef), uint256(1));
        attrs[1] = abi.encodePacked(transceiver.HYPERLANE_GAS_LIMIT_ATTRIBUTE(), uint256(1));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        transceiver.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_unknownAttributeIsRefused() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(bytes4(0xdeadbeef), uint256(1));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        transceiver.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_malformedGasLimitAttributeIsRefused() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(transceiver.HYPERLANE_GAS_LIMIT_ATTRIBUTE(), uint128(1));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        transceiver.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_supportedAttributeIsTheGasLimit() public view {
        assertEq(transceiver.HYPERLANE_GAS_LIMIT_ATTRIBUTE(), bytes4(keccak256("crossecute.hyperlane.gasLimit")));
    }

    function _lastPaid() internal view override returns (uint256) {
        return mailbox.sent(mailbox.sentLength() - 1).value;
    }

    function _setProviderFeePerByte(uint256 perByte) internal override {
        mailbox.setFeePerByte(perByte);
    }

    function _lastRefundAddress() internal view override returns (address) {
        return mailbox.sent(mailbox.sentLength() - 1).refundTo;
    }

    function _setProviderIdAsOwner(bytes32 chainKey, uint256 providerId) internal override {
        vm.prank(msig);
        transceiver.setDomain(chainKey, uint32(providerId));
    }

    function _deliverFromUnmappedOrigin(uint256 providerId) internal override {
        vm.prank(address(mailbox));
        transceiver.handle(uint32(providerId), TypeCasts.addressToBytes32(address(0xC0DE)), "");
    }

    function _unmappedOriginRevert(uint256 providerId) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(ProviderChainId.UnknownProviderId.selector, providerId);
    }
}

/// @notice `Mailbox.process` asserts nothing about the source-chain sender, so
///         `isSourceTransmitter` inside `handle` is the only sender check.
contract HyperlaneReceiveTest is ProviderWideSenderSpec {
    MockHyperlaneMailbox mailbox;
    HyperlaneReceiver receiver;
    address sourceTransmitter = address(0xABCD);

    function setUp() public {
        mailbox = new MockHyperlaneMailbox();
        receiver = HyperlaneReceiver(payable(_deployReceiver(new Call[](0))));
    }

    function _deployReceiver(Call[] memory calls) internal override returns (address proxy) {
        proxy = deployAccount(
            address(new HyperlaneReceiver(address(mailbox))),
            abi.encodeCall(HyperlaneReceiver.initialize, (sourceTransmitter, calls))
        );
    }

    function _receiverUnderTest() internal view override returns (address) {
        return address(receiver);
    }

    function _gateway() internal view override returns (address) {
        return address(mailbox);
    }

    function _deliverFromConfiguredSource() internal override {
        vm.prank(address(mailbox));
        receiver.handle(8453, TypeCasts.addressToBytes32(sourceTransmitter), Payload.encodeCalls(new Call[](0)));
    }

    function _deliverFromImpersonator() internal override {
        vm.prank(address(mailbox));
        receiver.handle(8453, TypeCasts.addressToBytes32(address(0xBAD)), "");
    }

    /// @dev `HyperlaneReceiver` keeps no origin state (same as `CcipReceiver`), so the
    ///      unconfigured-origin case is the impersonator case.
    function _deliverFromUnconfiguredOrigin() internal override {
        vm.prank(address(mailbox));
        receiver.handle(8453, TypeCasts.addressToBytes32(address(0xBAD)), "");
    }

    function _deliverFromWrongCaller() internal override {
        receiver.handle(8453, TypeCasts.addressToBytes32(sourceTransmitter), "");
    }

    function test_receiverGrantsTheMailboxTheGatewayRole() public view {
        assertTrue(receiver.hasRole(receiver.GATEWAY_ROLE(), address(mailbox)));
    }

    function _deliverFromWideSender(bytes32 wide) internal override {
        vm.prank(address(mailbox));
        receiver.handle(8453, wide, "");
    }

    function _wideSenderRevert(bytes32 wide) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(ProviderAddress.UnsupportedSender.selector, wide);
    }
}

contract HyperlaneTransmitterInboundTest is ProviderTransmitterSpec {
    address mailbox = address(0xBEEF);

    function _transmitter() internal override returns (address) {
        return address(
            deployAccount(
                address(new HyperlaneTransmitter(mailbox)),
                abi.encodeCall(OwnableTransmitter.initialize, (address(this), address(0xB0B), bytes32(0)))
            )
        );
    }

    function _deliveringGateway() internal view override returns (address) {
        return mailbox;
    }

    function _deliveryCall() internal pure override returns (bytes memory) {
        return abi.encodeCall(IMessageRecipient.handle, (8453, bytes32(uint256(0xABCD)), ""));
    }
}

