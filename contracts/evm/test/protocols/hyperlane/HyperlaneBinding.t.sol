// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {HyperlaneTransceiver} from "src/protocols/hyperlane/HyperlaneTransceiver.sol";
import {HyperlaneMessage} from "src/protocols/hyperlane/HyperlaneMessage.sol";
import {TypeCasts} from "@hyperlane/libs/TypeCasts.sol";
import {StandardHookMetadata} from "@hyperlane/hooks/libs/StandardHookMetadata.sol";

import {
    ProviderIdTableSpec,
    ProviderWideSenderSpec,
    ProviderEvmRecipientSpec,
    ProviderPayloadPricedSpec,
    ProviderRefundSpec,
    ProviderTransmitterSpec,
    ProviderTransmitterSendSpec,
    ProviderDefaultGasSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {HyperlaneFixture} from "test/protocols/hyperlane/HyperlaneFixture.sol";

contract HyperlaneTransceiverSendTest is
    ProviderIdTableSpec,
    ProviderEvmRecipientSpec,
    ProviderPayloadPricedSpec,
    ProviderRefundSpec,
    ProviderDefaultGasSpec,
    HyperlaneFixture
{
    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(mailbox.sentLength(), 1);
        assertEq(mailbox.sent(0).destinationDomain, BASE_DOMAIN);
    }

    function _supportedAttribute() internal pure override returns (bytes memory) {
        return abi.encodePacked(HyperlaneMessage.GAS_LIMIT_ATTRIBUTE, uint256(1));
    }

    function _gasLimitAttribute(uint256 gasLimit) internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(HyperlaneMessage.GAS_LIMIT_ATTRIBUTE, gasLimit);
    }

    function test_sendUsesTheRecipientsAddressAsBytes32() public {
        _sendPaid("x", new bytes[](0));
        assertEq(mailbox.sent(0).recipientAddress, TypeCasts.addressToBytes32(REMOTE_COUNTERPART));
    }

    function test_hookMetadataCarriesTheGasLimitAttributeAndRefundTarget() public {
        _sendPaid("x", _gasLimitAttribute(400_000));
        assertEq(mailbox.sent(0).metadata, StandardHookMetadata.formatMetadata(0, 400_000, address(this), ""));
    }

    /// @dev Without `refundAddress` in the metadata the refund goes to the sending contract,
    ///      and the transceiver's float would keep the payer's excess.
    function test_overpaymentIsRefundedToTheCallerNotTheTransceiver() public {
        mailbox.setFee(0.01 ether);
        address payer = address(0xFEE);
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        harness.sendMessagePublic{value: 0.03 ether}(_configuredRecipient(), "x", new bytes[](0), 0.03 ether);
        assertEq(payer.balance, 0.99 ether);
        assertEq(address(harness).balance, 0);
    }

    /// @dev #56: the real Mailbox quotes zero for a domain it does not route, and the dispatch is
    ///      never delivered. The quote and the send both refuse it.
    function test_aDomainThatQuotesZeroIsRefused() public {
        mailbox.setUnrouted(BASE_DOMAIN);
        bytes memory refusal = abi.encodeWithSelector(HyperlaneMessage.NoHyperlaneRoute.selector, BASE_DOMAIN);
        vm.expectRevert(refusal);
        harness.quoteMessagePublic(_configuredRecipient(), "x");
        vm.expectRevert(refusal);
        harness.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
    }

    function test_malformedGasLimitAttributeIsRefused() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(HyperlaneMessage.GAS_LIMIT_ATTRIBUTE, uint128(1));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        harness.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_supportedAttributeIsTheGasLimit() public view {
        assertEq(
            HyperlaneTransceiver(payable(address(harness))).HYPERLANE_GAS_LIMIT_ATTRIBUTE(),
            bytes4(keccak256("crossecute.hyperlane.gasLimit"))
        );
    }

    function _lastPaid() internal view override returns (uint256) {
        return mailbox.sent(mailbox.sentLength() - 1).value;
    }

    function _lastSentBody() internal view override returns (bytes memory) {
        return mailbox.sent(mailbox.sentLength() - 1).body;
    }

    function _setProviderFeePerByte(uint256 perByte) internal override {
        mailbox.setFeePerByte(perByte);
    }

    function _lastRefundAddress() internal view override returns (address) {
        return mailbox.sent(mailbox.sentLength() - 1).refundTo;
    }
}

/// @notice `Mailbox.process` asserts nothing about the source-chain sender, so
///         `isSourceTransmitter` inside `handle` is the only sender check. `HyperlaneReceiver`
///         keeps no origin state, so the unconfigured-origin case is the impersonator case.
contract HyperlaneReceiveTest is ProviderWideSenderSpec, HyperlaneFixture {}

contract HyperlaneTransmitterInboundTest is ProviderTransmitterSpec, HyperlaneFixture {}

contract HyperlaneTransmitterSendTest is ProviderTransmitterSendSpec, HyperlaneFixture {}
