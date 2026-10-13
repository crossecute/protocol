// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";

import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";

import {WormholeReceiver} from "src/protocols/wormhole/WormholeReceiver.sol";
import {WormholeTransceiver} from "src/protocols/wormhole/WormholeTransceiver.sol";
import {WormholeTransmitter} from "src/protocols/wormhole/WormholeTransmitter.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {DeliveryGas} from "src/messaging/DeliveryGas.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
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

    /* ============================== deferred execution ============================== */

    address internal constant PAYER = address(0xFEE);
    address internal constant STRANGER = address(0x5757);

    function _wt() internal view returns (WormholeTransceiver) {
        return WormholeTransceiver(payable(address(harness)));
    }

    /// @dev `PAYER` defers a send with a 0.02 ether budget, paying 0.05 ether with Core's fee at
    ///      0.001 ether; the first sequence is 0.
    function _defer(uint256 gas) internal {
        core.setMessageFee(0.001 ether);
        vm.deal(PAYER, 1 ether);
        vm.prank(PAYER);
        harness.sendMessagePublic{value: 0.05 ether}(
            _configuredRecipient(), "x", _deferredAttributes(gas, 0.02 ether), 0.05 ether
        );
    }

    function test_aDeferredSendPublishesAndEscrowsTheBudget() public {
        core.setMessageFee(0.001 ether);
        assertEq(
            harness.quoteMessagePublic(_configuredRecipient(), "x", _deferredAttributes(0, 0.02 ether)), 0.021 ether
        );
        _defer(0);
        assertEq(core.publishedLength(), 1);
        assertEq(executor.requestsLength(), 0, "nothing requested yet");
        assertEq(address(harness).balance, 0.02 ether);
        assertEq(PAYER.balance, 1 ether - 0.021 ether);
    }

    /// @dev The multisig case: the quote is fetched when execution is requested, long after the
    ///      send's calldata was fixed, by someone with no role.
    function test_anyoneRequestsADeferredExecutionWithAFreshQuote() public {
        _defer(0);
        vm.warp(block.timestamp + 3 days);
        bytes memory fresh = _quoteSignedBy(QUOTER_KEY, QUOTER, 0.01 ether);
        vm.prank(STRANGER);
        _wt().requestDeferredExecution(0, fresh);

        MockExecutor.Request memory r = executor.requests(0);
        assertEq(r.dstChain, BASE_WORMHOLE_CHAIN);
        assertEq(r.dstAddr, toBytes32(REMOTE_COUNTERPART));
        assertEq(r.refundAddr, PAYER);
        assertEq(r.signedQuote, fresh);
        assertEq(
            r.requestBytes, RequestLib.encodeVaaMultiSigRequest(HERE_WORMHOLE_CHAIN, toBytes32(address(harness)), 0)
        );
        assertEq(_lastGasLimit(), DeliveryGas.BOOTSTRAP, "the default for what the payload is");
        assertEq(PAYEE.balance, 0.01 ether);
        assertEq(PAYER.balance, 1 ether - 0.011 ether, "the unspent budget returns to the payer");
        assertEq(address(harness).balance, 0);
    }

    function test_theDeferredGasIsTheGasRequested() public {
        _defer(300_000);
        _wt().requestDeferredExecution(0, _quoteSignedBy(QUOTER_KEY, QUOTER, 0.01 ether));
        assertEq(_lastGasLimit(), 300_000);
    }

    function test_aDeferralIsRequestedOnce() public {
        _defer(0);
        bytes memory fresh = _quoteSignedBy(QUOTER_KEY, QUOTER, 0.01 ether);
        _wt().requestDeferredExecution(0, fresh);
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.UnknownDeferral.selector, uint64(0)));
        _wt().requestDeferredExecution(0, fresh);
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.UnknownDeferral.selector, uint64(1)));
        _wt().requestDeferredExecution(1, fresh);
    }

    /// @dev Without the signature check a caller could name any payee and a price up to the
    ///      budget, and be paid from the escrow.
    function test_aQuoteNotSignedByItsQuoterIsRefused() public {
        _defer(0);
        uint256 otherKey = 0xBAD;
        bytes memory forged = _quoteSignedBy(otherKey, QUOTER, 0.01 ether);
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.QuoteSignerMismatch.selector, vm.addr(otherKey), QUOTER));
        _wt().requestDeferredExecution(0, forged);

        bytes memory unsigned = _quoteSignedBy(QUOTER_KEY, QUOTER, 0.01 ether);
        for (uint256 i = 100; i < 165; ++i) {
            unsigned[i] = 0;
        }
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignature.selector));
        _wt().requestDeferredExecution(0, unsigned);
    }

    /// @dev A rotated or second provider's key is paid once the owner approves it.
    function test_onlyAnApprovedQuoterIsPaid() public {
        _defer(0);
        uint256 rotatedKey = 0x0908;
        address rotated = vm.addr(rotatedKey);
        bytes memory quote = _quoteSignedBy(rotatedKey, rotated, 0.01 ether);
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.QuoterNotApproved.selector, rotated));
        _wt().requestDeferredExecution(0, quote);

        vm.expectRevert();
        vm.prank(STRANGER);
        _wt().setQuoter(rotated, true);

        vm.prank(_wt().owner());
        _wt().setQuoter(rotated, true);
        assertTrue(_wt().isQuoter(rotated));
        _wt().requestDeferredExecution(0, quote);
        assertEq(PAYEE.balance, 0.01 ether);
    }

    function test_aQuoteAboveTheBudgetIsRefused() public {
        _defer(0);
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.QuoteAboveBudget.selector, 0.03 ether, 0.02 ether));
        _wt().requestDeferredExecution(0, _quoteSignedBy(QUOTER_KEY, QUOTER, 0.03 ether));
    }

    function test_anExpiredQuoteCannotRequestADeferral() public {
        _defer(0);
        bytes memory quote = _quoteSignedBy(QUOTER_KEY, QUOTER, 0.01 ether);
        uint64 expiry = uint64(block.timestamp + 1 hours);
        vm.warp(expiry);
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.QuoteExpired.selector, expiry));
        _wt().requestDeferredExecution(0, quote);
    }

    function test_aDeferralBelowItsBudgetIsRefused() public {
        core.setMessageFee(0.001 ether);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(WormholeMessage.InsufficientWormholeValue.selector, 0.02 ether, 0.021 ether)
        );
        harness.sendMessagePublic{value: 0.02 ether}(
            _configuredRecipient(), "x", _deferredAttributes(0, 0.02 ether), 0.02 ether
        );
    }

    function test_aBudgetAboveUint128IsRefused() public {
        bytes[] memory attrs = _deferredAttributes(0, uint256(type(uint128).max) + 1);
        _refusesQuoteAndSend(attrs, abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
    }

    /// @dev The treasury withdraws the float, never a payer's escrow.
    function test_withdrawLeavesTheEscrow() public {
        _defer(0);
        vm.deal(address(harness), address(harness).balance + 0.005 ether);
        address treasury = _wt().treasury();
        vm.prank(treasury);
        vm.expectRevert(
            abi.encodeWithSelector(WormholeTransceiver.EscrowNotWithdrawable.selector, 0.025 ether, 0.005 ether)
        );
        _wt().withdraw(0.025 ether);
        vm.prank(treasury);
        _wt().withdraw(0.005 ether);
        assertEq(address(harness).balance, 0.02 ether);
    }

    /// @dev Wormhole Labs' production quoter signs as `_requireApprovedQuoter` checks: the live
    ///      quote pays out once its quoter is approved.
    function test_aLiveQuoteRecoversToItsQuoter() public {
        vm.warp(LIVE_QUOTE_EXPIRY - 60);
        core.setMessageFee(0);
        vm.deal(PAYER, 1 ether);
        vm.prank(PAYER);
        harness.sendMessagePublic{value: 0.001 ether}(
            _configuredRecipient(), "x", _deferredAttributes(1_000_000, 0.001 ether), 0.001 ether
        );
        address liveQuoter = 0xa54008017941EcE968623a0Dd8Ee907E2b133596;
        vm.prank(_wt().owner());
        _wt().setQuoter(liveQuoter, true);
        _wt().requestDeferredExecution(0, LIVE_QUOTE);
        assertEq(executor.requests(0).paid, 84_081_300_000_000);
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

contract WormholeTransmitterSendTest is ProviderTransmitterSendSpec, WormholeFixture {
    function _deferredSend(uint256 maxPrice) internal {
        bytes memory recipient = TransmitterBase(account).recipientOn(REMOTE_CHAIN_ID);
        vm.prank(ACCOUNT_OWNER);
        TransmitterBase(account).sendMessage(recipient, "x", _deferredAttributes(0, maxPrice));
    }

    /// @dev The owner's send fixes no quote; anyone later pays from the escrow left in the
    ///      account, under a quoter the account's transceiver approves.
    function test_anOwnersDeferredSendIsExecutedByAnyone() public {
        _setProviderFee(0);
        uint64 seq = core.nextSequence(account);
        uint256 before = account.balance;
        _deferredSend(0.02 ether);
        assertEq(before - account.balance, CORE_MESSAGE_FEE, "only Core's fee leaves the account");
        assertEq(WormholeTransmitter(account).escrowed(), 0.02 ether);

        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0x5757));
        WormholeTransmitter(account).requestDeferredExecution(seq, _quoteSignedBy(QUOTER_KEY, QUOTER, 0.01 ether));
        MockExecutor.Request memory r = executor.requests(executor.requestsLength() - 1);
        assertEq(r.refundAddr, account);
        assertEq(r.requestBytes, RequestLib.encodeVaaMultiSigRequest(HERE_WORMHOLE_CHAIN, toBytes32(account), seq));
        assertEq(before - account.balance, CORE_MESSAGE_FEE + 0.01 ether);
        assertEq(WormholeTransmitter(account).escrowed(), 0);
    }

    /// @dev A later send pays from the same balance and must leave the escrow.
    function test_aSendCannotSpendTheEscrow() public {
        _setProviderFee(0.009 ether);
        vm.deal(account, 0.02 ether + CORE_MESSAGE_FEE + 0.009 ether);
        _deferredSend(0.02 ether);
        bytes memory recipient = TransmitterBase(account).recipientOn(REMOTE_CHAIN_ID);
        vm.prank(ACCOUNT_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(WormholeMessage.EscrowSpent.selector, 0.02 ether - CORE_MESSAGE_FEE, 0.02 ether)
        );
        TransmitterBase(account).sendMessage(recipient, "x", _attributes());
    }

    /// @dev A multisig owner's bootstrap: the transceiver publishes and holds the escrow, and the
    ///      unspent budget returns to the account that paid it.
    function test_aDeferredBootstrapIsExecutedByAnyone() public {
        _setProviderFee(0);
        address payable transceiver = payable(TransmitterBase(account).transceiver());
        vm.prank(ACCOUNT_OWNER);
        address payable second = payable(WormholeTransceiver(transceiver).createTransmitter(bytes32(uint256(1))));
        vm.deal(second, 1 ether);
        vm.prank(ACCOUNT_OWNER);
        TransmitterBase(second).bootstrap(REMOTE_CHAIN_ID, new Call[](0), _deferredAttributes(0, 0.02 ether));
        assertEq(transceiver.balance, 0.02 ether, "the transceiver holds the escrow");

        uint64 seq = core.nextSequence(transceiver) - 1;
        vm.prank(address(0x5757));
        WormholeTransceiver(transceiver).requestDeferredExecution(seq, _quoteSignedBy(QUOTER_KEY, QUOTER, 0.01 ether));
        assertEq(executor.requests(executor.requestsLength() - 1).refundAddr, second);
        assertEq(_lastGasLimit(), DeliveryGas.BOOTSTRAP);
        assertEq(second.balance, 1 ether - CORE_MESSAGE_FEE - 0.01 ether);
        assertEq(transceiver.balance, 0);
    }

    function test_theTransmitterSupportsBothAttributes() public view {
        assertTrue(TransmitterBase(account).supportsAttribute(WormholeMessage.EXECUTION_ATTRIBUTE));
        assertTrue(TransmitterBase(account).supportsAttribute(WormholeMessage.DEFERRED_ATTRIBUTE));
    }
}
