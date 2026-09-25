// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";

/// @notice The wrapper every provider's hub-send test harness exposes: a thin subclass of the
///         real hub transceiver that makes `_sendMessage`/`_quoteMessage` callable directly,
///         so a test can exercise the translation layer without going through the full
///         registry-gated `TransmitterBase.sendMessage` entry point. See `LzHubHarness`.
interface IHubSendHarness {
    function sendMessagePublic(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value
    ) external payable returns (bytes32);

    function quoteMessagePublic(bytes memory recipient, bytes memory payload)
        external
        view
        returns (uint256);
}

/// @title ProviderHubSendSpec
/// @notice The properties every native provider binding's hub send path must satisfy,
///         independent of which provider it is. A concrete per-provider suite (e.g.
///         `LzBinding.t.sol:LzSendTest`) inherits this and implements the hooks below against
///         its own mock provider endpoint; the test bodies run unchanged.
///
/// @dev `_sendMessage`/`_quoteMessage` differ only in how they translate an ERC-7930
///      recipient into the provider's own destination id and price the send; that a
///      configured destination resolves correctly, an unconfigured one reverts, and the quote
///      matches what the send actually pays is identical across LayerZero, CCIP, Hyperlane,
///      Wormhole, and OP Stack. Each concrete suite still owns its own provider-specific mock
///      (e.g. `MockLzEndpoint`) and harness contract; this only fixes what that mock has to
///      support and what has to be true of it.
abstract contract ProviderHubSendSpec is Test {
    /// @notice The harness under test, set in the concrete suite's `setUp`.
    IHubSendHarness internal harness;

    /// @notice A recipient on a chain the concrete suite has configured a real destination
    ///         for (provider id/selector/domain, and a counterpart/peer), built with the same
    ///         `Erc7930`/`ChainKey` helpers a real caller would use.
    function _configuredRecipient() internal view virtual returns (bytes memory);

    /// @notice A well-formed recipient on a chain nothing has configured.
    function _unconfiguredRecipient() internal view virtual returns (bytes memory);

    /// @notice Set the provider mock's fee for the next quote/send, in native currency.
    function _setProviderFee(uint256 fee) internal virtual;

    /// @notice Assert the provider mock recorded a send targeting the same provider-native
    ///         destination `_configuredRecipient()` resolves to (e.g. LayerZero's
    ///         `MockLzEndpoint.sent(0).dstEid`). This is where the translation is checked.
    function _assertLastSendTargetedConfiguredDestination() internal view virtual;

    /// @notice The quote expected when the provider mock charges `providerFee`. The provider's
    ///         fee by default; a provider with no native fee (OP Stack) overrides it to zero.
    function _expectedQuoteFor(uint256 providerFee) internal view virtual returns (uint256) {
        return providerFee;
    }

    function test_sendResolvesTheConfiguredDestination() public {
        harness.sendMessagePublic(_configuredRecipient(), "payload", new bytes[](0), 0);
        _assertLastSendTargetedConfiguredDestination();
    }

    function test_quoteMatchesWhatSendWouldPay() public {
        uint256 fee = 0.02 ether;
        _setProviderFee(fee);
        assertEq(harness.quoteMessagePublic(_configuredRecipient(), "x"), _expectedQuoteFor(fee));
    }

    /// @dev ERC-7786: a gateway returns zero once the message is sent, and a non-zero id means a
    ///      further gateway-specific step is required. `TransmitterBase.sendMessage` emits
    ///      `MessageSent` with zero and returns this value, so a native binding returning its
    ///      provider's own message id would contradict its own event. The provider's id stays
    ///      available in the provider's events. Checks a second send too: a provider counter
    ///      (a nonce or sequence) starts at zero and would pass on the first alone.
    function test_aCompletedSendReturnsZero() public {
        assertEq(harness.sendMessagePublic(_configuredRecipient(), "payload", new bytes[](0), 0), bytes32(0));
        assertEq(harness.sendMessagePublic(_configuredRecipient(), "payload", new bytes[](0), 0), bytes32(0));
    }

    function test_sendRevertsForAnUnconfiguredDestination() public {
        vm.expectRevert();
        harness.sendMessagePublic(_unconfiguredRecipient(), "x", new bytes[](0), 0);
    }
}

/// @title ProviderReceiveSpec
/// @notice The properties every native provider binding's receive path must satisfy,
///         independent of which provider it is: the configured source is accepted, an
///         impersonator is rejected, an unconfigured origin is rejected, and a caller that is
///         not the provider's own gateway/endpoint/mailbox/router/relayer/messenger is
///         rejected. A concrete suite (e.g. `LzBinding.t.sol:LzReceiveTest`) inherits this and
///         drives its own receiver and mock through the four scenarios below.
///
/// @dev How each scenario is triggered is provider-specific: LayerZero's peer check runs
///      inside the vendored OApp SDK before this protocol's own code sees the call, while
///      Hyperlane/CCIP/Wormhole/OP Stack check `GATEWAY_ROLE` in their own inbound entry
///      point. This spec asserts only the observable property (revert, or `Delivered`), never
///      where the check runs — that distinction is a per-provider fact worth its own comment
///      in the concrete suite, not something this spec can verify.
abstract contract ProviderReceiveSpec is Test {
    event Delivered(uint256 callCount);

    /// @notice The receiver under test, so `Delivered` can be matched to its exact emitter.
    function _receiverUnderTest() internal view virtual returns (address);

    /// @notice Deliver a payload exactly as the provider's real transport would, from the one
    ///         source this receiver was configured to trust. Results in `Delivered(0)`.
    /// @dev No payload argument: what counts as a validly-encoded empty payload is a property
    ///      of the destination chain's own wire format (`Payload.encodeCalls`, here), which
    ///      the concrete suite already knows and this spec has no business choosing.
    function _deliverFromConfiguredSource() internal virtual;

    /// @notice Deliver through the same call path as above, but as any source other than the
    ///         configured one. Reverts.
    function _deliverFromImpersonator() internal virtual;

    /// @notice Deliver as though from a real, correctly-authenticated message whose origin
    ///         (chain/domain/eid/selector) was never configured on this receiver. Reverts.
    function _deliverFromUnconfiguredOrigin() internal virtual;

    /// @notice Call the receiver's inbound entry point directly, bypassing the provider's own
    ///         gateway/endpoint/mailbox/router/relayer/messenger entirely. Reverts.
    function _deliverFromWrongCaller() internal virtual;

    /// @notice The address this receiver's initializer granted `GATEWAY_ROLE`.
    function _gateway() internal view virtual returns (address);

    function test_theConfiguredSourceIsAccepted() public {
        vm.expectEmit(false, false, false, true, _receiverUnderTest());
        emit Delivered(0);
        _deliverFromConfiguredSource();
    }

    function test_anImpersonatorIsRejected() public {
        vm.expectRevert();
        _deliverFromImpersonator();
    }

    function test_anUnconfiguredOriginIsRejected() public {
        vm.expectRevert();
        _deliverFromUnconfiguredOrigin();
    }

    function test_anythingButTheProvidersOwnGatewayIsRejected() public {
        vm.expectRevert();
        _deliverFromWrongCaller();
    }

    /// @dev `revokeGateway` is an account's only way to disconnect a transport, so it must cut
    ///      delivery even where the provider authenticates before this protocol's code runs.
    function test_aRevokedGatewayCannotDeliver() public {
        ReceiverBase receiver = ReceiverBase(payable(_receiverUnderTest()));
        vm.prank(receiver.sourceTransmitter());
        receiver.revokeGateway(_gateway());
        vm.expectRevert();
        _deliverFromConfiguredSource();
    }
}
