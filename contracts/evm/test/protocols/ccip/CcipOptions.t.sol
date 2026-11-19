// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CcipFixture, CcipTransceiverHarness} from "test/protocols/ccip/CcipFixture.sol";
import {MockCcipRouter} from "test/protocols/ccip/MockCcipRouter.sol";
import {ProviderTransmitterFixture} from "test/protocols/ProviderBindingSpec.t.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
import {CcipTransceiver, CcipTransceiverBase} from "src/protocols/ccip/CcipTransceiver.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";
import {GasAttribute} from "script/deploy/GasAttribute.sol";
import {DeliveryGas} from "src/messaging/DeliveryGas.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Call} from "src/messaging/Call.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {ExtraArgsCodec} from "@chainlink/contracts-ccip/contracts/libraries/ExtraArgsCodec.sol";

abstract contract CcipOptionsSpec is ProviderTransmitterFixture, CcipFixture {
    CcipTransceiver private configuredTransceiver;
    bytes internal configuredRecipient;

    function setUp() public override {
        super.setUp();
        configuredTransceiver = CcipTransceiver(payable(TransmitterBase(conduit).transceiver()));
        configuredRecipient = TransmitterBase(conduit).recipientOn(REMOTE_CHAIN_ID);
        vm.deal(address(this), 10 ether);
    }

    function _defaultGas() internal pure virtual returns (uint256);
    function _payer() internal view virtual returns (address);

    function _quote(bytes[] memory attrs) internal view virtual returns (uint256);
    function _send(bytes[] memory attrs, uint256 fee) internal virtual;

    function _t() internal view returns (CcipTransceiver) {
        return configuredTransceiver;
    }

    function _payload() internal pure returns (bytes memory) {
        return Payload.encodeCalls(new Call[](0));
    }

    function _lane(bool enabled) internal {
        vm.prank(_t().owner());
        _t().setCcipV3Lane(BASE_SELECTOR, enabled, keccak256("local test lane"));
    }

    function _options() internal pure returns (ExtraArgsCodec.GenericExtraArgsV3 memory options) {
        options.gasLimit = 500_000;
        options.ccvs = new address[](0);
        options.ccvArgs = new bytes[](0);
    }

    function _attrs(ExtraArgsCodec.GenericExtraArgsV3 memory options) internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = GasAttribute.ccip(options);
    }

    function _bothReject(bytes[] memory attrs) internal {
        vm.expectRevert();
        _quote(attrs);
        vm.expectRevert();
        _send(attrs, 0);
    }

    function _assertSent(bytes[] memory attrs, bytes memory expected) internal {
        router.setFee(10_000);
        router.configureV3Pricing(7, false);
        uint256 quote = _quote(attrs);
        uint256 beforeBalance = _payer().balance;
        _send(attrs, quote);
        assertEq(beforeBalance - _payer().balance, quote);
        MockCcipRouter.Sent memory sent = router.sent(router.sentLength() - 1);
        assertEq(sent.extraArgs, expected);
        assertEq(sent.data, _payload());
        assertEq(sent.value, 10_000 + 7 * expected.length);
        assertGe(quote, sent.value);
        assertEq(sent.feeToken, address(0));
    }

    function test_defaultsRemainV2EvenWhenV3IsEnabled() public {
        bytes memory expected = abi.encodeWithSelector(bytes4(0x181dcf10), _defaultGas(), false);
        _assertSent(new bytes[](0), expected);
        _lane(true);
        _assertSent(new bytes[](0), expected);
        bytes[] memory explicitDefault = new bytes[](1);
        explicitDefault[0] = GasAttribute.ccip(_defaultGas());
        _assertSent(explicitDefault, expected);
    }

    function test_v3NeedsLaneAndTracksDisablingAndReenabling() public {
        bytes[] memory attrs = _attrs(_options());
        _bothReject(attrs);
        _lane(true);
        _assertSent(attrs, abi.encodePacked(bytes4(0xa69dd4aa), uint32(500_000), bytes4(0), bytes7(0)));
        _lane(false);
        _bothReject(attrs);
        _lane(true);
        _assertSent(attrs, abi.encodePacked(bytes4(0xa69dd4aa), uint32(500_000), bytes4(0), bytes7(0)));
    }

    function test_providerRejectionDoesNotFallBackToV2() public {
        _lane(true);
        router.configureV3Pricing(0, true);
        bytes[] memory attrs = _attrs(_options());
        _bothReject(attrs);
        _quote(new bytes[](0));
        _send(new bytes[](0), _quote(new bytes[](0)));
        assertEq(bytes4(router.sent(router.sentLength() - 1).extraArgs), bytes4(0x181dcf10));
    }

    function testFuzz_v3GasAndFinalityRoundTrip(uint32 gasLimit, uint16 depth) public {
        _lane(true);
        ExtraArgsCodec.GenericExtraArgsV3 memory options = _options();
        options.gasLimit = gasLimit;
        options.requestedFinalityConfig = bytes4(uint32(depth));
        _assertSent(
            _attrs(options),
            abi.encodePacked(
                bytes4(0xa69dd4aa), gasLimit == 0 ? uint32(_defaultGas()) : gasLimit, bytes4(uint32(depth)), bytes7(0)
            )
        );
    }

    function test_customVerifiersExecutorAndNoExecAreEncodedAndPriced() public {
        _lane(true);
        ExtraArgsCodec.GenericExtraArgsV3 memory options = _options();
        options.ccvs = new address[](2);
        options.ccvs[0] = address(0);
        options.ccvs[1] = address(0xCC);
        options.ccvArgs = new bytes[](2);
        options.ccvArgs[1] = hex"1234";
        options.executorArgs = hex"abcd";
        options.requestedFinalityConfig = bytes4(0x00010000);
        bytes memory verifierPrefix = abi.encodePacked(
            bytes4(0xa69dd4aa),
            uint32(500_000),
            bytes4(0x00010000),
            uint8(2),
            uint8(0),
            uint16(0),
            uint8(20),
            address(0xCC),
            uint16(2),
            hex"1234"
        );
        address[2] memory executors = [address(0xEE), Client.NO_EXECUTION_ADDRESS];
        for (uint256 i; i < executors.length; ++i) {
            options.executor = executors[i];
            bytes memory expected =
                abi.encodePacked(verifierPrefix, uint8(20), executors[i], uint16(2), hex"abcd", uint8(0), uint16(0));
            assertEq(expected.length, 69);
            _assertSent(_attrs(options), expected);
        }
    }

    function test_invalidOptionsAreRejectedByQuoteAndSend() public {
        _lane(true);
        ExtraArgsCodec.GenericExtraArgsV3 memory options = _options();
        options.tokenReceiver = hex"01";
        _bothReject(_attrs(options));
        options.tokenReceiver = "";
        options.tokenArgs = hex"01";
        _bothReject(_attrs(options));
        options.tokenArgs = "";
        options.requestedFinalityConfig = bytes4(0x00010001);
        _bothReject(_attrs(options));
        options.requestedFinalityConfig = bytes4(0x00020000);
        _bothReject(_attrs(options));
        options.requestedFinalityConfig = bytes4(0);
        options.ccvs = new address[](1);
        _bothReject(_attrs(options));
        options.ccvs = new address[](2);
        options.ccvArgs = new bytes[](2);
        _bothReject(_attrs(options));
        options.ccvs = new address[](0);
        options.ccvArgs = new bytes[](0);
        options.executorArgs = new bytes(65_536);
        _bothReject(_attrs(options));
    }

    function test_mixedDuplicateAndMalformedAttributesAreRejected() public {
        _lane(true);
        bytes[] memory attrs = new bytes[](2);
        attrs[0] = GasAttribute.ccip(_options());
        attrs[1] = GasAttribute.ccip(1);
        _bothReject(attrs);
        attrs[1] = attrs[0];
        _bothReject(attrs);
        attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(CcipMessage.EXTRA_ARGS_V3_ATTRIBUTE, bytes32(0));
        _bothReject(attrs);
        attrs[0] = abi.encodePacked(CcipMessage.EXTRA_ARGS_V3_ATTRIBUTE, abi.encode(uint256(type(uint32).max) + 1));
        _bothReject(attrs);
    }

    function test_v3RejectsGasWordOverflowAndVerifierArgumentLimits() public {
        _lane(true);
        ExtraArgsCodec.GenericExtraArgsV3 memory options = _options();
        bytes memory body = abi.encode(options);
        assembly { mstore(add(body, 64), 0x100000000) }
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(CcipMessage.EXTRA_ARGS_V3_ATTRIBUTE, body);
        _bothReject(attrs);
        options.ccvs = new address[](1);
        options.ccvArgs = new bytes[](1);
        options.ccvArgs[0] = new bytes(65_536);
        _bothReject(_attrs(options));
        options.ccvs = new address[](256);
        options.ccvArgs = new bytes[](256);
        _bothReject(_attrs(options));
    }

    function test_onlyOwnerCanEnableKnownLaneWithEvidence() public {
        vm.expectRevert();
        _t().setCcipV3Lane(BASE_SELECTOR, true, bytes32(uint256(1)));
        address owner = _t().owner();
        vm.startPrank(owner);
        vm.expectRevert(CcipTransceiverBase.MissingCcipLaneEvidence.selector);
        _t().setCcipV3Lane(BASE_SELECTOR, true, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(ProviderChainId.UnknownProviderId.selector, uint256(123)));
        _t().setCcipV3Lane(123, true, bytes32(uint256(1)));
        vm.stopPrank();
        assertFalse(_t().ccipV3LaneEnabled(BASE_SELECTOR));
    }
}

contract CcipTransmitterOptionsTest is CcipOptionsSpec {
    function _payer() internal view override returns (address) {
        return conduit;
    }

    function _defaultGas() internal pure override returns (uint256) {
        return DeliveryGas.PAYLOAD;
    }

    function _quote(bytes[] memory attrs) internal view override returns (uint256) {
        return TransmitterBase(conduit).quoteMessage(configuredRecipient, _payload(), attrs);
    }

    function _send(bytes[] memory attrs, uint256) internal override {
        bytes memory recipient = configuredRecipient;
        vm.prank(CONDUIT_OWNER);
        TransmitterBase(conduit).sendMessage(recipient, _payload(), attrs);
    }
}

contract CcipTransceiverOptionsTest is CcipOptionsSpec {
    function _payer() internal view override returns (address) {
        return address(this);
    }

    function _defaultGas() internal pure override returns (uint256) {
        return DeliveryGas.BOOTSTRAP;
    }

    function _quote(bytes[] memory attrs) internal view override returns (uint256) {
        return CcipTransceiverHarness(payable(address(_t()))).quoteMessagePublic(configuredRecipient, _payload(), attrs);
    }

    function _send(bytes[] memory attrs, uint256 fee) internal override {
        bytes memory recipient = configuredRecipient;
        CcipTransceiverHarness(payable(address(_t()))).sendMessagePublic{value: fee}(recipient, _payload(), attrs, fee);
    }
}
