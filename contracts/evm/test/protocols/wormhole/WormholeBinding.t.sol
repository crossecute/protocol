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
import {MockExecutor} from "test/protocols/wormhole/MockExecutor.sol";
import {
    ProviderIdTableSpec,
    ProviderWideSenderSpec,
    ProviderEvmRecipientSpec,
    ProviderFeeSpec,
    ProviderRefundSpec,
    ProviderTransmitterSpec,
    ProviderTransmitterSendSpec,
    ProviderDefaultGasSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {toBytes32} from "test/protocols/ProviderFixture.sol";
import {WormholeFixture, _vaa, _envelope} from "test/protocols/wormhole/WormholeFixture.sol";

contract WormholeTransceiverSendTest is
    ProviderIdTableSpec,
    ProviderEvmRecipientSpec,
    ProviderFeeSpec,
    ProviderRefundSpec,
    ProviderDefaultGasSpec,
    WormholeFixture
{
    /// @dev Fetched from `executor.labsapis.com/v0/quote` on 2026-10-07 for Ethereum (2) to Base
    ///      (30) and 1,000,000 gas; the API answered `estimatedCost` 84,081,300,000,000 wei.
    bytes internal constant LIVE_QUOTE =
        hex"45513031a54008017941ece968623a0dd8ee907e2b1335960000000000000000000000006a8bfc410a3cc7306d52872f116afb12f1cec6c60002001e000000006ac7337a00000000000bea0d00000000005b8d800000174bcb40af000000174bcb40af00bb67be36695b6322bf555fe6120d22a1ecb8d6e0897eb4fd0df32471ffd94eaa79d708a06d1bbd242a7ec7deba14c41f40856b847b9dcbc8182e6448d982ce841c";
    uint64 internal constant LIVE_QUOTE_EXPIRY = 1_791_439_738;

    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(executor.requestsLength(), 1);
        assertEq(executor.requests(0).dstChain, BASE_WORMHOLE_CHAIN);
    }

    function _supportedAttribute() internal view override returns (bytes memory) {
        return _gasAttribute(1);
    }

    function _with(bytes memory signedQuote, uint256 gas) internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = _executionAttribute(signedQuote, gas);
    }

    function _refusesQuoteAndSend(bytes[] memory attrs, bytes memory refusal) internal {
        vm.expectRevert(refusal);
        harness.quoteMessagePublic(_configuredRecipient(), "x", attrs);
        vm.expectRevert(refusal);
        harness.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_publishedPayloadNamesItsDestination() public {
        harness.sendMessagePublic(_configuredRecipient(), "payload", _attributes(), 0);
        MockWormholeCore.Published memory p = core.published(0);
        assertEq(p.emitter, address(harness));
        assertEq(p.payload, _envelope(BASE_WORMHOLE_CHAIN, REMOTE_COUNTERPART, "payload"));
        assertEq(p.consistencyLevel, 1);
    }

    function test_executionRequestCarriesTheQuoteAndNamesTheVaa() public {
        address payer = address(0xFEE);
        bytes memory signedQuote = _signedQuote();
        vm.prank(payer);
        harness.sendMessagePublic(_configuredRecipient(), "x", _with(signedQuote, 0), 0);
        MockExecutor.Request memory r = executor.requests(0);
        assertEq(r.dstAddr, toBytes32(REMOTE_COUNTERPART));
        assertEq(r.refundAddr, payer);
        assertEq(r.signedQuote, signedQuote);
        assertEq(
            r.requestBytes, RequestLib.encodeVaaMultiSigRequest(HERE_WORMHOLE_CHAIN, toBytes32(address(harness)), 0)
        );
    }

    function test_quoteIsMessageFeePlusThePriceTheQuoteStates() public {
        _setProviderFee(0.01 ether);
        core.setMessageFee(0.001 ether);
        assertEq(harness.quoteMessagePublic(_configuredRecipient(), "x", _attributes()), 0.011 ether);
    }

    /// @dev The binding's price for a real provider quote is the provider's own answer.
    function test_aLiveQuoteIsPricedAsTheExecutorApiPricesIt() public {
        vm.warp(LIVE_QUOTE_EXPIRY - 60);
        core.setMessageFee(0);
        assertEq(
            harness.quoteMessagePublic(_configuredRecipient(), "x", _with(LIVE_QUOTE, 1_000_000)), 84_081_300_000_000
        );
    }

    /// @dev Destination gas is converted at the ratio of the two USD prices.
    function test_gasIsPricedAtTheDestinationsRate() public {
        core.setMessageFee(0);
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes memory parity = _eq01(BASE_WORMHOLE_CHAIN, expiry, 0, 2 gwei, 1, 1);
        bytes memory dearer = _eq01(BASE_WORMHOLE_CHAIN, expiry, 0, 2 gwei, 1, 3);
        assertEq(harness.quoteMessagePublic(_configuredRecipient(), "x", _with(parity, 100_000)), 100_000 * 2 gwei);
        assertEq(harness.quoteMessagePublic(_configuredRecipient(), "x", _with(dearer, 100_000)), 3 * 100_000 * 2 gwei);
    }

    /// @dev The Executor forwards all it is sent to the payee, so the binding sends it the price
    ///      alone and refunds the rest itself.
    function test_thePayeeGetsThePriceAndThePayerTheRest() public {
        _setProviderFee(0.01 ether);
        core.setMessageFee(0.001 ether);
        address payer = address(0xFEE);
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        harness.sendMessagePublic{value: 0.03 ether}(_configuredRecipient(), "x", _attributes(), 0.03 ether);
        assertEq(core.published(0).value, 0.001 ether);
        assertEq(PAYEE.balance, 0.01 ether);
        assertEq(payer.balance, 0.989 ether);
        assertEq(address(harness).balance, 0);
    }

    function test_valueBelowThePriceIsRefused() public {
        _setProviderFee(0.01 ether);
        core.setMessageFee(0.001 ether);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(WormholeMessage.InsufficientWormholeValue.selector, 0.005 ether, 0.011 ether)
        );
        harness.sendMessagePublic{value: 0.005 ether}(_configuredRecipient(), "x", _attributes(), 0.005 ether);
    }

    /// @dev #53: no on-chain quoter is deployed, so a send without a provider's quote has no price
    ///      and no relayer.
    function test_noQuoteIsRefused() public {
        _refusesQuoteAndSend(new bytes[](0), abi.encodeWithSelector(WormholeMessage.NoSignedQuote.selector));
    }

    function test_anExpiredQuoteIsRefused() public {
        bytes[] memory attrs = _attributes();
        uint64 expiry = uint64(block.timestamp + 1 hours);
        vm.warp(expiry);
        _refusesQuoteAndSend(attrs, abi.encodeWithSelector(WormholeMessage.QuoteExpired.selector, expiry));
    }

    function test_aQuoteForAnotherRouteIsRefused() public {
        bytes memory other = _eq01(31, uint64(block.timestamp + 1 hours), 1, 0, 1, 1);
        _refusesQuoteAndSend(
            _with(other, 0),
            abi.encodeWithSelector(WormholeMessage.QuoteForAnotherRoute.selector, HERE_WORMHOLE_CHAIN, uint16(31))
        );
    }

    function test_onlyAnEq01QuoteIsPriced() public {
        bytes memory eq02 = _signedQuote();
        eq02[3] = "2";
        _refusesQuoteAndSend(_with(eq02, 0), abi.encodeWithSelector(WormholeMessage.UnsupportedQuote.selector));
        bytes memory zeroPrice = _eq01(BASE_WORMHOLE_CHAIN, uint64(block.timestamp + 1 hours), 1, 1, 0, 1);
        _refusesQuoteAndSend(_with(zeroPrice, 0), abi.encodeWithSelector(WormholeMessage.UnsupportedQuote.selector));
    }

    function test_gasLimitAboveUint128IsRefused() public {
        bytes[] memory attrs = _with(_signedQuote(), uint256(type(uint128).max) + 1);
        _refusesQuoteAndSend(attrs, abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
    }

    /// @dev Core's message fee plus what the payee was paid.
    function _lastPaid() internal view override returns (uint256) {
        return core.published(core.publishedLength() - 1).value + executor.requests(executor.requestsLength() - 1).paid;
    }

    function _lastRefundAddress() internal view override returns (address) {
        return executor.requests(executor.requestsLength() - 1).refundAddr;
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
