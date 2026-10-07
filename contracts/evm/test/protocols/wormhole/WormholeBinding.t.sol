// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";

import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";

import {WormholeReceiver} from "src/protocols/wormhole/WormholeReceiver.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";
import {RequestLib} from "@wormhole-sdk/Executor/Request.sol";
import {CoreBridgeVM} from "@wormhole-sdk/interfaces/ICoreBridge.sol";

import {MockWormholeCore} from "test/protocols/wormhole/MockWormholeCore.sol";
import {MockExecutorQuoterRouter} from "test/protocols/wormhole/MockExecutorQuoterRouter.sol";
import {
    ProviderIdTableSpec,
    ProviderWideSenderSpec,
    ProviderEvmRecipientSpec,
    ProviderFeeSpec,
    ProviderRefundSpec,
    ProviderTransmitterSpec,
    ProviderTransmitterSendSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {toBytes32} from "test/protocols/ProviderFixture.sol";
import {WormholeFixture, _vaa, _envelope} from "test/protocols/wormhole/WormholeFixture.sol";

contract WormholeTransceiverSendTest is
    ProviderIdTableSpec,
    ProviderEvmRecipientSpec,
    ProviderFeeSpec,
    ProviderRefundSpec,
    WormholeFixture
{
    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(router.requestsLength(), 1);
        assertEq(router.requests(0).dstChain, BASE_WORMHOLE_CHAIN);
    }

    function _supportedAttribute() internal pure override returns (bytes memory) {
        return abi.encodePacked(WormholeMessage.GAS_LIMIT_ATTRIBUTE, uint256(1));
    }

    function _gasLimitAttribute(uint256 gasLimit) internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(WormholeMessage.GAS_LIMIT_ATTRIBUTE, gasLimit);
    }

    function test_publishedPayloadNamesItsDestination() public {
        harness.sendMessagePublic(_configuredRecipient(), "payload", new bytes[](0), 0);
        MockWormholeCore.Published memory p = core.published(0);
        assertEq(p.emitter, address(harness));
        assertEq(p.payload, _envelope(BASE_WORMHOLE_CHAIN, REMOTE_COUNTERPART, "payload"));
        assertEq(p.consistencyLevel, 1);
    }

    function test_executionRequestNamesTheVaaAndTheRecipient() public {
        address payer = address(0xFEE);
        vm.prank(payer);
        harness.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        MockExecutorQuoterRouter.Request memory r = router.requests(0);
        assertEq(r.dstAddr, toBytes32(REMOTE_COUNTERPART));
        assertEq(r.refundAddr, payer);
        assertEq(r.quoterAddr, QUOTER);
        assertEq(
            r.requestBytes, RequestLib.encodeVaaMultiSigRequest(HERE_WORMHOLE_CHAIN, toBytes32(address(harness)), 0)
        );
    }

    function test_gasLimitDefaultsAndFollowsTheAttribute() public {
        harness.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        harness.sendMessagePublic(_configuredRecipient(), "x", _gasLimitAttribute(750_000), 0);
        assertEq(router.requests(0).relayInstructions, abi.encodePacked(uint8(1), uint128(200_000), uint128(0)));
        assertEq(router.requests(1).relayInstructions, abi.encodePacked(uint8(1), uint128(750_000), uint128(0)));
    }

    function test_quoteIsMessageFeePlusExecutionPrice() public {
        core.setMessageFee(0.001 ether);
        router.setFee(0.01 ether);
        assertEq(harness.quoteMessagePublic(_configuredRecipient(), "x"), 0.011 ether);
    }

    function test_valueSplitsBetweenCoreAndTheRouterWithExcessRefunded() public {
        core.setMessageFee(0.001 ether);
        router.setFee(0.01 ether);
        address payer = address(0xFEE);
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        harness.sendMessagePublic{value: 0.03 ether}(_configuredRecipient(), "x", new bytes[](0), 0.03 ether);
        assertEq(core.published(0).value, 0.001 ether);
        assertEq(router.requests(0).paid, 0.01 ether);
        assertEq(payer.balance, 0.989 ether);
        assertEq(address(harness).balance, 0);
    }

    function test_valueBelowTheMessageFeeIsRefused() public {
        core.setMessageFee(0.001 ether);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(WormholeMessage.InsufficientWormholeValue.selector, 0.0005 ether, 0.001 ether)
        );
        harness.sendMessagePublic{value: 0.0005 ether}(_configuredRecipient(), "x", new bytes[](0), 0.0005 ether);
    }

    function test_gasLimitAboveUint128IsRefused() public {
        bytes[] memory attrs = _gasLimitAttribute(uint256(type(uint128).max) + 1);
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        harness.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    /// @dev Core's message fee plus what the Executor router kept (it refunds the rest).
    function _lastPaid() internal view override returns (uint256) {
        return core.published(core.publishedLength() - 1).value + router.requests(router.requestsLength() - 1).paid;
    }

    function _lastRefundAddress() internal view override returns (address) {
        return router.requests(router.requestsLength() - 1).refundAddr;
    }
}

/// @notice `executeVAAv1` is permissionless: guardian signatures (checked by Core) authenticate
///         the emitter, and `isSourceTransmitter` is the only sender check. `WormholeReceiver`
///         keeps no origin state, so the unconfigured-origin case is the impersonator case.
contract WormholeReceiveTest is ProviderWideSenderSpec, WormholeFixture {
    function _validVaa(uint64 seq) internal view returns (bytes memory) {
        return _vaa(
            1, BASE_WORMHOLE_CHAIN, SOURCE_TRANSMITTER, seq, _envelope(HERE_WORMHOLE_CHAIN, receiver, _emptyPayload())
        );
    }

    function test_aReplayedVaaIsRejected() public {
        bytes memory vaa = _validVaa(0);
        WormholeReceiver(payable(receiver)).executeVAAv1(vaa);
        (CoreBridgeVM memory v,,) = core.parseAndVerifyVM(vaa);
        bytes32 hash = v.hash;
        assertTrue(WormholeReceiver(payable(receiver)).vaaConsumed(hash));
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.VaaAlreadyConsumed.selector, hash));
        WormholeReceiver(payable(receiver)).executeVAAv1(vaa);
    }

    /// @dev C30: the consumed mark rolls back with a delivery that reverts, so the same VAA
    ///      succeeds once the cause is fixed rather than being lost.
    function test_aFailedDeliveryIsStillRetryable() public {
        Switch sw = new Switch();
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(sw), value: 0, data: abi.encodeCall(Switch.run, ())});
        bytes memory vaa = _vaa(
            1,
            BASE_WORMHOLE_CHAIN,
            SOURCE_TRANSMITTER,
            0,
            _envelope(HERE_WORMHOLE_CHAIN, receiver, Payload.encodeCalls(calls))
        );

        vm.expectRevert();
        WormholeReceiver(payable(receiver)).executeVAAv1(vaa);
        sw.fix();
        WormholeReceiver(payable(receiver)).executeVAAv1(vaa);
        assertTrue(sw.ran());
    }

    /// @dev C31: each account keeps its own consumed set, so one consuming its message does not
    ///      stop another receiving its own with the same source and sequence.
    function test_theDedupeIsPerAccount() public {
        WormholeReceiver other = WormholeReceiver(payable(_deployReceiver(new Call[](0))));
        bytes memory first = _validVaa(0);
        WormholeReceiver(payable(receiver)).executeVAAv1(first);
        (CoreBridgeVM memory v,,) = core.parseAndVerifyVM(first);
        assertFalse(other.vaaConsumed(v.hash));
        other.executeVAAv1(
            _vaa(
                1,
                BASE_WORMHOLE_CHAIN,
                SOURCE_TRANSMITTER,
                0,
                _envelope(HERE_WORMHOLE_CHAIN, address(other), Payload.encodeCalls(new Call[](0)))
            )
        );
    }

    /// @dev Receivers share one address across parity chains; a VAA for another chain must not
    ///      run here.
    function test_aVaaForAnotherChainIsRejected() public {
        bytes memory vaa = _vaa(
            1, BASE_WORMHOLE_CHAIN, SOURCE_TRANSMITTER, 0, _envelope(31, receiver, Payload.encodeCalls(new Call[](0)))
        );
        vm.expectRevert(
            abi.encodeWithSelector(WormholeMessage.WrongDestination.selector, uint16(31), toBytes32(receiver))
        );
        WormholeReceiver(payable(receiver)).executeVAAv1(vaa);
    }

    function test_aVaaForAnotherAddressIsRejected() public {
        bytes memory vaa = _vaa(
            1,
            BASE_WORMHOLE_CHAIN,
            SOURCE_TRANSMITTER,
            0,
            _envelope(HERE_WORMHOLE_CHAIN, address(0xD1FF), Payload.encodeCalls(new Call[](0)))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                WormholeMessage.WrongDestination.selector, HERE_WORMHOLE_CHAIN, toBytes32(address(0xD1FF))
            )
        );
        WormholeReceiver(payable(receiver)).executeVAAv1(vaa);
    }

    /// @dev `revokeGateway(coreBridge)` must still disconnect Wormhole even though the Core
    ///      bridge never calls in.
    function test_revokingTheCoreBridgeGatewayDisconnectsWormhole() public {
        vm.prank(SOURCE_TRANSMITTER);
        WormholeReceiver(payable(receiver)).revokeGateway(address(core));
        vm.expectRevert(WormholeMessage.WormholeGatewayRevoked.selector);
        WormholeReceiver(payable(receiver)).executeVAAv1(_validVaa(0));
    }

    function test_aPayloadDifferentFromWhatCoreVerifiedIsRejected() public {
        core.setPayloadOverride("something else");
        vm.expectRevert(WormholeMessage.MalformedVaa.selector);
        WormholeReceiver(payable(receiver)).executeVAAv1(_validVaa(0));
    }

    function test_signatureCountSetsThePayloadOffset() public {
        vm.expectEmit(false, false, false, true, receiver);
        emit Delivered(0);
        WormholeReceiver(payable(receiver))
            .executeVAAv1(
                _vaa(
                    13,
                    BASE_WORMHOLE_CHAIN,
                    SOURCE_TRANSMITTER,
                    0,
                    _envelope(HERE_WORMHOLE_CHAIN, receiver, Payload.encodeCalls(new Call[](0)))
                )
            );
    }

    function test_nonzeroValueIsRejected() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(WormholeMessage.UnexpectedValue.selector);
        WormholeReceiver(payable(receiver)).executeVAAv1{value: 1}(_validVaa(0));
    }
}

contract WormholeTransmitterInboundTest is ProviderTransmitterSpec, WormholeFixture {}

/// @dev A payload target that fails until fixed, for C30.
contract Switch {
    bool public broken = true;
    bool public ran;

    function fix() external {
        broken = false;
    }

    function run() external {
        require(!broken, "broken");
        ran = true;
    }
}

contract WormholeTransmitterSendTest is ProviderTransmitterSendSpec, WormholeFixture {}
