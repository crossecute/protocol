// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";

import {HyperlaneHubTransceiver} from "src/protocols/hyperlane/HyperlaneHubTransceiver.sol";
import {HyperlaneSpokeTransceiver, HyperlaneSpokeBase} from "src/protocols/hyperlane/HyperlaneSpokeTransceiver.sol";
import {
    HyperlaneZkSyncSpokeTransceiver,
    HyperlaneTronSpokeTransceiver
} from "src/protocols/hyperlane/HyperlaneDivergentSpokeTransceiver.sol";
import {IMessageRecipient} from "@hyperlane/interfaces/IMessageRecipient.sol";
import {HyperlaneReceiver} from "src/protocols/hyperlane/HyperlaneReceiver.sol";
import {TypeCasts} from "@hyperlane/libs/TypeCasts.sol";
import {StandardHookMetadata} from "@hyperlane/hooks/libs/StandardHookMetadata.sol";

import {MockHyperlaneMailbox} from "test/protocols/hyperlane/MockHyperlaneMailbox.sol";
import {ProviderIdTableSpec, IHubSendHarness, ProviderWideSenderSpec, ProviderSpokeOriginSpec, ProviderEvmRecipientSpec, ProviderPayloadPricedSpec} from "test/protocols/ProviderBindingSpec.t.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Exposes `_sendMessage`/`_quoteMessage` directly (bootstrap/ownership machinery is
///         covered by `test/Transport.t.sol`).
contract HyperlaneHubHarness is HyperlaneHubTransceiver {
    constructor(address mailbox) HyperlaneHubTransceiver(mailbox) {}

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

contract HyperlaneSendTest is ProviderIdTableSpec, ProviderEvmRecipientSpec, ProviderPayloadPricedSpec {
    MockHyperlaneMailbox mailbox;
    HyperlaneHubHarness hub;
    address msig = address(0x5165);
    uint32 constant BASE_DOMAIN = 8453;

    function setUp() public {
        mailbox = new MockHyperlaneMailbox();
        hub = HyperlaneHubHarness(
            address(
                new ERC1967Proxy(
                    address(new HyperlaneHubHarness(address(mailbox))),
                    abi.encodeCall(
                        HyperlaneHubTransceiver.initialize, (msig, address(0), new address[](0), address(0xBEEF))
                    )
                )
            )
        );
        harness = IHubSendHarness(address(hub));

        vm.prank(msig);
        hub.setDomain(ChainKey.forEvm(8453), BASE_DOMAIN);
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
        attrs[0] = abi.encodePacked(hub.HYPERLANE_GAS_LIMIT_ATTRIBUTE(), gasLimit);
    }

    function test_sendUsesTheRecipientsAddressAsBytes32() public {
        hub.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        assertEq(mailbox.sent(0).recipientAddress, TypeCasts.addressToBytes32(address(0xC0DE)));
    }

    function test_sendForwardsThePayloadAndValueUnchanged() public {
        mailbox.setFee(0.01 ether);
        vm.deal(address(this), 1 ether);
        hub.sendMessagePublic{value: 0.01 ether}(_configuredRecipient(), "payload", new bytes[](0), 0.01 ether);
        assertEq(mailbox.sent(0).body, "payload");
        assertEq(mailbox.sent(0).value, 0.01 ether);
    }

    function test_hookMetadataCarriesTheGasLimitAttributeAndRefundTarget() public {
        hub.sendMessagePublic(_configuredRecipient(), "x", _gasLimitAttribute(400_000), 0);
        assertEq(mailbox.sent(0).metadata, StandardHookMetadata.formatMetadata(0, 400_000, address(this), ""));
    }

    function test_noAttributeMeansTheIgpDefaultGasLimit() public {
        hub.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        assertEq(mailbox.sent(0).metadata, StandardHookMetadata.formatMetadata(0, 50_000, address(this), ""));
    }

    /// @dev Without `refundAddress` in the metadata the refund goes to the hub, which has no
    ///      `receive`, and the overpaid send reverts.
    function test_overpaymentIsRefundedToTheCallerNotTheHub() public {
        mailbox.setFee(0.01 ether);
        address payer = address(0xFEE);
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        hub.sendMessagePublic{value: 0.03 ether}(_configuredRecipient(), "x", new bytes[](0), 0.03 ether);
        assertEq(payer.balance, 0.99 ether);
        assertEq(address(hub).balance, 0);
    }

    /// @dev A malformed first attribute is reported even when an extra follows it.
    function test_malformedFirstAttributeIsReportedBeforeAnExtra() public {
        bytes[] memory attrs = new bytes[](2);
        attrs[0] = abi.encodePacked(bytes4(0xdeadbeef), uint256(1));
        attrs[1] = abi.encodePacked(hub.HYPERLANE_GAS_LIMIT_ATTRIBUTE(), uint256(1));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        hub.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_unknownAttributeIsRefused() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(bytes4(0xdeadbeef), uint256(1));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        hub.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_malformedGasLimitAttributeIsRefused() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(hub.HYPERLANE_GAS_LIMIT_ATTRIBUTE(), uint128(1));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        hub.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_supportedAttributeIsTheGasLimit() public view {
        assertEq(hub.HYPERLANE_GAS_LIMIT_ATTRIBUTE(), bytes4(keccak256("crossecute.hyperlane.gasLimit")));
    }

    function _lastPaid() internal view override returns (uint256) {
        return mailbox.sent(mailbox.sentLength() - 1).value;
    }

    function _setProviderFeePerByte(uint256 perByte) internal override {
        mailbox.setFeePerByte(perByte);
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
        receiver = HyperlaneReceiver(
            payable(address(
                    new ERC1967Proxy(
                        address(new HyperlaneReceiver(address(mailbox))),
                        abi.encodeCall(HyperlaneReceiver.initialize, (sourceTransmitter, new Call[](0)))
                    )
                ))
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

contract HyperlaneTransceiverReceiveTest is Test {
    MockHyperlaneMailbox mailbox;
    HyperlaneSpokeTransceiver spoke;
    HyperlaneHubTransceiver hub;
    uint32 constant HOME_DOMAIN = 1;
    address homeTransceiver = address(0xD00D);

    function setUp() public {
        mailbox = new MockHyperlaneMailbox();
        spoke = _spoke(HOME_DOMAIN);
        hub = HyperlaneHubTransceiver(
            address(
                new ERC1967Proxy(
                    address(new HyperlaneHubTransceiver(address(mailbox))),
                    abi.encodeCall(
                        HyperlaneHubTransceiver.initialize,
                        (address(this), address(0), new address[](0), address(0xBEEF))
                    )
                )
            )
        );
    }

    function _spoke(uint32 homeDomain) internal returns (HyperlaneSpokeTransceiver) {
        return HyperlaneSpokeTransceiver(
            address(
                new ERC1967Proxy(
                    address(new HyperlaneSpokeTransceiver(address(mailbox))),
                    abi.encodeCall(
                        HyperlaneSpokeTransceiver.initialize,
                        (
                            new address[](0),
                            address(0xC0DE),
                            ChainKey.forEvm(1),
                            Erc7930.encodeEvmChain(1),
                            abi.encodePacked(homeTransceiver),
                            homeDomain
                        )
                    )
                )
            )
        );
    }

    function test_hubAndSpokeGrantTheMailboxTheGatewayRole() public view {
        assertTrue(hub.hasRole(hub.GATEWAY_ROLE(), address(mailbox)));
        assertTrue(spoke.hasRole(spoke.GATEWAY_ROLE(), address(mailbox)));
    }

    function test_spokeRejectsZeroHomeDomain() public {
        HyperlaneSpokeTransceiver impl = new HyperlaneSpokeTransceiver(address(mailbox));
        vm.expectRevert(HyperlaneSpokeBase.ZeroHomeDomain.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                HyperlaneSpokeTransceiver.initialize,
                (
                    new address[](0),
                    address(0xC0DE),
                    ChainKey.forEvm(1),
                    Erc7930.encodeEvmChain(1),
                    abi.encodePacked(homeTransceiver),
                    uint32(0)
                )
            )
        );
    }

    function test_spokeRejectsANonHubSenderFromHome() public {
        vm.prank(address(mailbox));
        vm.expectRevert();
        spoke.handle(HOME_DOMAIN, TypeCasts.addressToBytes32(address(0xBAD)), "");
    }

    function test_spokeRejectsAnyCallerButTheMailbox() public {
        vm.expectRevert();
        spoke.handle(HOME_DOMAIN, TypeCasts.addressToBytes32(homeTransceiver), "");
    }

    function test_hubRejectsAnUnmappedOrigin() public {
        vm.prank(address(mailbox));
        vm.expectRevert(abi.encodeWithSelector(ProviderChainId.UnknownProviderId.selector, uint256(999)));
        hub.handle(999, TypeCasts.addressToBytes32(address(0xC0DE)), "");
    }

    function test_hubRejectsAnyCallerButTheMailbox() public {
        vm.expectRevert();
        hub.handle(1, TypeCasts.addressToBytes32(address(0xC0DE)), "");
    }
}

contract HyperlaneSpokeOriginTest is ProviderSpokeOriginSpec {
    MockHyperlaneMailbox mailbox = new MockHyperlaneMailbox();
    address hub = address(0xD00D);
    uint32 constant HOME_DOMAIN = 1;

    function _spokes() internal override returns (address[] memory spokes) {
        bytes memory hubBytes = abi.encodePacked(hub);
        spokes = new address[](3);
        spokes[0] = address(
            new ERC1967Proxy(
                address(new HyperlaneSpokeTransceiver(address(mailbox))),
                abi.encodeCall(
                    HyperlaneSpokeTransceiver.initialize,
                    (new address[](0), address(0xC0DE), ChainKey.forEvm(1), Erc7930.encodeEvmChain(1), hubBytes, HOME_DOMAIN)
                )
            )
        );
        spokes[1] = address(
            new ERC1967Proxy(
                address(new HyperlaneZkSyncSpokeTransceiver(address(mailbox))),
                abi.encodeCall(
                    HyperlaneZkSyncSpokeTransceiver.initialize,
                    (new address[](0), address(0xC0DE), ChainKey.forEvm(1), Erc7930.encodeEvmChain(1), hubBytes, bytes32(uint256(1)), HOME_DOMAIN)
                )
            )
        );
        spokes[2] = address(
            new ERC1967Proxy(
                address(new HyperlaneTronSpokeTransceiver(address(mailbox))),
                abi.encodeCall(
                    HyperlaneTronSpokeTransceiver.initialize,
                    (new address[](0), address(0xC0DE), ChainKey.forEvm(1), Erc7930.encodeEvmChain(1), hubBytes, bytes32(uint256(1)), HOME_DOMAIN)
                )
            )
        );
    }

    function _otherOrigin() internal pure override returns (uint256) {
        return 2;
    }

    function _deliverFromHubOn(address spoke, uint256 origin) internal override {
        vm.prank(address(mailbox));
        IMessageRecipient(spoke).handle(uint32(origin), TypeCasts.addressToBytes32(hub), "");
    }
}
