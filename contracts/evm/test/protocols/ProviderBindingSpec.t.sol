// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SlotReuse} from "test/protocols/SlotReuse.t.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {providerIdOf, ProviderChainId, IProviderIdTable} from "src/protocols/ProviderChainId.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {unseeded} from "test/RegistrySeed.sol";
import {ChainRegistry, RegistrySeed, ProviderSeed} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Envelope} from "src/messaging/Envelope.sol";

/// @notice The wrapper every provider's send test harness exposes: a thin subclass of the
///         real transceiver that makes `_sendMessage`/`_quoteMessage` callable directly,
///         so a test can exercise the translation layer without going through the full
///         registry-gated `TransmitterBase.sendMessage` entry point. See `LzTransceiverHarness`.
interface ISendHarness {
    function sendMessagePublic(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        external
        payable
        returns (bytes32);

    function quoteMessagePublic(bytes memory recipient, bytes memory payload) external view returns (uint256);
}

/// @title ProviderSendSpec
/// @notice The properties every native provider binding's transceiver send path must satisfy,
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
abstract contract ProviderSendSpec is Test {
    /// @notice The harness under test, set in the concrete suite's `setUp`.
    ISendHarness internal harness;

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

    /// @dev C13 (R2.5): a quote that succeeded where the send reverts reports a message as
    ///      sendable when it is not.
    function test_quoteRevertsWhereTheSendWould() public {
        vm.expectRevert();
        harness.quoteMessagePublic(_unconfiguredRecipient(), "x");
    }

    /// @dev C14 (R2.2): a quote is only ever an `eth_call`.
    function test_quoteIsView() public view {
        (bool ok,) =
            address(harness).staticcall(abi.encodeCall(ISendHarness.quoteMessagePublic, (_configuredRecipient(), "x")));
        assertTrue(ok);
    }
}

/// @title ProviderFeeSpec
/// @notice For providers that charge a native fee at the source (all but OP Stack): what the
///         quote names is what the send pays, from `value`, and paying less is refused.
abstract contract ProviderFeeSpec is ProviderSendSpec {
    /// @notice What the provider's mocks were paid, in total, for the last send.
    function _lastPaid() internal view virtual returns (uint256);

    /// @dev C11 against the mock; the real endpoint's C11 is a fork test (`docs/todo.md` §3).
    function test_quoteEqualsWhatTheSendActuallyConsumes() public {
        _setProviderFee(0.02 ether);
        uint256 q = harness.quoteMessagePublic(_configuredRecipient(), "payload");
        harness.sendMessagePublic{value: q}(_configuredRecipient(), "payload", new bytes[](0), q);
        assertEq(_lastPaid(), q);
    }

    /// @dev C16.
    function test_anUnderfundedSendReverts() public {
        _setProviderFee(0.02 ether);
        uint256 q = harness.quoteMessagePublic(_configuredRecipient(), "payload");
        vm.expectRevert();
        harness.sendMessagePublic{value: q - 1}(_configuredRecipient(), "payload", new bytes[](0), q - 1);
    }

    /// @dev C26 (R7.1, R7.3): a nested send arrives with `msg.value == 0` and pays from the
    ///      contract's balance, so the binding must spend `value`, never `msg.value`.
    function test_aSendIsPaidFromValueNotMsgValue() public {
        _setProviderFee(0.02 ether);
        uint256 q = harness.quoteMessagePublic(_configuredRecipient(), "payload");
        vm.deal(address(harness), q);
        harness.sendMessagePublic(_configuredRecipient(), "payload", new bytes[](0), q);
        assertEq(_lastPaid(), q);
    }
}

/// @title ProviderRefundSpec
/// @notice C25 (R7.2): a transceiver's overpayment is refunded to its caller, the account on
///         path B, never to itself. A transmitter refunds to itself, as the payer
///         (`Transport.t.sol`). For providers that refund (LayerZero, Hyperlane, Wormhole); CCIP
///         keeps overpayment.
abstract contract ProviderRefundSpec is ProviderFeeSpec {
    /// @notice The refund address the provider was given for the last send.
    function _lastRefundAddress() internal view virtual returns (address);

    function test_excessRefundsToTheCallerNotTheSender() public {
        _setProviderFee(0.02 ether);
        uint256 overpaid = 2 * harness.quoteMessagePublic(_configuredRecipient(), "payload");
        address caller = makeAddr("caller");
        vm.deal(caller, overpaid);
        vm.prank(caller);
        harness.sendMessagePublic{value: overpaid}(_configuredRecipient(), "payload", new bytes[](0), overpaid);
        assertEq(_lastRefundAddress(), caller);
    }
}

/// @title ProviderPayloadPricedSpec
/// @notice C12 (R2.3), for providers that price by payload length (LayerZero, CCIP, Hyperlane;
///         Wormhole's Executor and OP Stack do not).
abstract contract ProviderPayloadPricedSpec is ProviderFeeSpec {
    function _setProviderFeePerByte(uint256 perByte) internal virtual;

    function test_quoteIsTakenOverTheExactPayloadBytes() public {
        _setProviderFeePerByte(1 gwei);
        bytes memory longer = "a longer payload than the other one";
        uint256 short = harness.quoteMessagePublic(_configuredRecipient(), "x");
        uint256 long = harness.quoteMessagePublic(_configuredRecipient(), longer);
        assertGt(long, short);
        harness.sendMessagePublic{value: long}(_configuredRecipient(), longer, new bytes[](0), long);
        assertEq(_lastPaid(), long);
    }
}

/// @title ProviderIdTableSpec
/// @notice For transceivers with a provider id table: what every transmitter reads on each send, through
///         the same `providerIdOf` it calls.
abstract contract ProviderIdTableSpec is ProviderSendSpec {
    /// @notice The id the concrete suite set for `_configuredRecipient()`'s chain.
    function _configuredProviderId() internal view virtual returns (uint256);

    /// @notice Call the transceiver's typed setter, as its owner.
    function _setProviderIdAsOwner(bytes32 chainKey, uint256 providerId) internal virtual;

    /// @notice Deliver to the transceiver through the provider's own path, from an origin id
    ///         never set.
    function _deliverFromUnmappedOrigin(uint256 providerId) internal virtual;

    /// @notice The exact revert for that delivery.
    function _unmappedOriginRevert(uint256 providerId) internal view virtual returns (bytes memory);

    function test_transmittersReadTheConfiguredIdFromTheTransceiver() public {
        assertEq(providerIdOf(address(harness), _configuredRecipient()), _configuredProviderId());
        vm.expectRevert(
            abi.encodeWithSelector(ProviderChainId.NoProviderIdFor.selector, Erc7930.chainKey(_unconfiguredRecipient()))
        );
        providerIdOf(address(harness), _unconfiguredRecipient());
    }

    /// @dev C28 for the one setter a binding adds: repointing a chain's id would silently
    ///      redirect its future sends.
    function test_theTypedSetterIsWriteOnce() public {
        bytes32 chainKey = Erc7930.chainKey(_configuredRecipient());
        _setProviderIdAsOwner(chainKey, _configuredProviderId());
        vm.expectRevert(abi.encodeWithSelector(ProviderChainId.ProviderIdAlreadySet.selector, chainKey));
        _setProviderIdAsOwner(chainKey, _configuredProviderId() + 1);
    }

    /// @dev C5, transceiver side: a delivery whose origin the table does not map is refused.
    function test_aDeliveryFromAnUnmappedOriginIsRefused() public {
        vm.expectRevert(_unmappedOriginRevert(999));
        _deliverFromUnmappedOrigin(999);
    }
}

/// @title ProviderEvmRecipientSpec
/// @notice For bindings that deliver to the recipient's address as an EVM address: a recipient
///         whose address is not 20 bytes is refused rather than truncated into another one.
abstract contract ProviderEvmRecipientSpec is ProviderSendSpec {
    function test_aNonEvmWidthRecipientIsRefused() public {
        bytes memory wide = abi.encodePacked(bytes32(uint256(0xC0DE)));
        bytes memory recipient =
            Erc7930.encode(Erc7930.CT_EIP155, Erc7930.parseStrict(_configuredRecipient()).chainRef, wide);
        vm.expectRevert(abi.encodeWithSelector(ProviderAddress.UnsupportedRecipient.selector, wide));
        harness.sendMessagePublic(recipient, "x", new bytes[](0), 0);
    }
}

/// @title ProviderTransmitterSpec
/// @notice C9 (R3.1): a transmitter has no inbound path. Its provider's delivery callback,
///         called by the provider's own gateway, finds nothing to run.
abstract contract ProviderTransmitterSpec is Test {
    /// @notice A transmitter behind a proxy, initialized.
    function _transmitter() internal virtual returns (address);

    /// @notice The provider's delivery callback, encoded as its gateway would call it.
    function _deliveryCall() internal view virtual returns (bytes memory);

    function _deliveringGateway() internal view virtual returns (address);

    function test_inboundToATransmitterReverts() public {
        address transmitter = _transmitter();
        vm.prank(_deliveringGateway());
        (bool ok,) = transmitter.call(_deliveryCall());
        assertFalse(ok);
    }
}

/// @notice Called from a receiver's bootstrap payload: fails unless the receiver already
///         lets `gateway` deliver.
contract ProviderConfiguredProbe {
    bytes32 constant GATEWAY_ROLE = keccak256("crossecute.role.GATEWAY");

    error GatewayNotYetConfigured(address gateway);

    function requireGateway(address gateway) external view {
        if (!IAccessControl(msg.sender).hasRole(GATEWAY_ROLE, gateway)) revert GatewayNotYetConfigured(gateway);
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

    /// @notice A new receiver behind a proxy whose initializer runs `calls` as its bootstrap
    ///         payload.
    function _deployReceiver(Call[] memory calls) internal virtual returns (address);

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

    /// @dev C18: the bootstrap payload runs inside the receiver's one initializer call, so the
    ///      provider must already be configured when it does, or a first call that relies on
    ///      it fails with no second chance.
    function test_theProviderIsConfiguredBeforeTheBootstrapPayloadRuns() public {
        ProviderConfiguredProbe probe = new ProviderConfiguredProbe();
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(probe), value: 0, data: abi.encodeCall(probe.requireGateway, (_gateway()))});
        _deployReceiver(calls);
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

    /// @dev C24 for the account, which holds the provider's delivery state beside its own.
    function test_aDeliveryWritesOverNoOtherField() public {
        vm.startStateDiffRecording();
        _deliverFromConfiguredSource();
        address[] memory accounts = new address[](1);
        accounts[0] = _receiverUnderTest();
        SlotReuse.assertNone(vm.stopAndReturnStateDiff(), accounts);
    }
}

/// @title ProviderWideSenderSpec
/// @notice C10 (R4.3): a provider-reported sender wider than 20 bytes, whose low 20 bytes are
///         the configured source, is refused rather than truncated into it. For providers that
///         report the sender in more than 20 bytes (all but OP Stack).
abstract contract ProviderWideSenderSpec is ProviderReceiveSpec {
    /// @notice Deliver through the provider's own path, from `wide`, as its gateway would.
    function _deliverFromWideSender(bytes32 wide) internal virtual;

    /// @notice The exact revert expected, so the test cannot pass by failing for another reason.
    function _wideSenderRevert(bytes32 wide) internal view virtual returns (bytes memory);

    function test_aWideSenderIsRejectedNotTruncated() public {
        address source = ReceiverBase(payable(_receiverUnderTest())).sourceTransmitter();
        bytes32 wide = bytes32(uint256(uint160(source)) | (uint256(1) << 200));
        vm.expectRevert(_wideSenderRevert(wide));
        _deliverFromWideSender(wide);
    }
}

/// @title ProviderInboundSpec
/// @title ProviderGovernorHomeSpec
/// @notice #28: on any chain but the governor's home, the transceiver's owner is created by a
///         bootstrap from that home, so a binding with a provider id table names the home's id
///         at initialization rather than leaving it to an owner that does not exist yet.
abstract contract ProviderGovernorHomeSpec is Test {
    /// @notice Deploy the plain transceiver with `id` as the governor home's provider id and
    ///         Ethereum as the governor's home.
    function _deployWithGovernorHomeId(uint256 id) internal virtual returns (address);

    function test_theGovernorHomeIdIsNamedAtInitialization() public {
        address t = _deployWithGovernorHomeId(7);
        assertEq(IProviderIdTable(t).providerIdFor(ChainKey.forEvm(1)), 7);
        assertEq(TransceiverBase(payable(t)).routeFor(ChainKey.forEvm(1)), Erc7930.encodeEvmChain(1), "and its route");
    }
}

/// @notice What every binding's transceiver must satisfy on the
///         way in: a bootstrap from a configured origin, arriving through the provider's own
///         path, creates a receiver configured for that provider; a wrong sender is refused;
///         and the float can be funded and leaves only to the treasury.
/// @dev The plain variant only. zkSync and Tron variants fail closed at account creation on
///      Forge's EVM, so their suites pin their own overrides instead.
abstract contract ProviderInboundSpec is Test {
    event InboundHandled(bytes32 chainKey);

    uint256 internal constant ORIGIN_CHAIN_ID = 8453;
    /// @dev The origin's transceiver as this one records it. `Unique`, so no parity check.
    address internal constant ORIGIN_TRANSCEIVER = address(0xC0DE);
    address internal constant ACCOUNT_OWNER = address(0xA11CE);
    bytes32 internal constant ACCOUNT_SALT = keccak256("account");
    address internal constant ORIGIN_TRANSMITTER = address(0x7A11);

    /// @notice The transceiver under test, emitting `InboundHandled(origin)` as it handles a
    ///         message, with a receiver implementation for its provider and a treasury.
    function _transceiver() internal view virtual returns (address);

    /// @notice Provider-side configuration for the origin: its provider id, and anything the
    ///         provider needs to accept `ORIGIN_TRANSCEIVER` (a LayerZero peer). As the owner.
    function _configureOrigin(bytes32 chainKey) internal virtual;

    /// @notice Deliver `message` to `transceiver` through the provider's own path, from
    ///         `ORIGIN_CHAIN_ID`.
    function _deliverTo(address transceiver, address sender, bytes memory message) internal virtual;

    /// @notice Deploy the plain transceiver born knowing only the governor's home,
    ///         `ORIGIN_CHAIN_ID`: `registry`, provider `keccak256("under-test")`, a `Unique`
    ///         bar, and the provider's id for that home, with no owner call afterwards.
    function _deployBornConfigured(IChainRegistryRefs registry, address governorOwner, bytes32 governorSalt)
        internal
        virtual
        returns (address);

    function _deliver(address sender, bytes memory message) internal {
        _deliverTo(_transceiver(), sender, message);
    }

    /// @notice The revert for a wrong sender: the base's by default.
    function _wrongSenderRevert(bytes32 chainKey, address) internal view virtual returns (bytes memory) {
        return abi.encodeWithSelector(TransceiverBase.NotCounterpart.selector, chainKey);
    }

    /// @notice Assert the receiver was configured for the provider before its payload ran
    ///         (R6). Nothing to check by default.
    function _assertReceiverConfigured(address receiver, address transmitter) internal view virtual {}

    function _wire() internal returns (bytes32 chainKey) {
        TransceiverBase t = TransceiverBase(payable(_transceiver()));
        ChainRegistry registry = new ChainRegistry(address(this), unseeded());
        bytes32 provider = registry.addMessageProvider("under-test");
        chainKey = registry.addChainKey(Erc7930.encodeEvmChain(ORIGIN_CHAIN_ID), Provenance.Unique);

        vm.startPrank(t.owner());
        t.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Unique);
        t.setCounterpart(chainKey, Erc7930.encodeEvm(ORIGIN_CHAIN_ID, ORIGIN_TRANSCEIVER));
        t.setRoute(chainKey, Erc7930.encodeEvmChain(ORIGIN_CHAIN_ID));
        vm.stopPrank();
        _configureOrigin(chainKey);
    }

    function _bootstrap() internal pure returns (bytes memory) {
        return Envelope.encodeBootstrap(
            ACCOUNT_OWNER, ACCOUNT_SALT, bytes32(uint256(uint160(ORIGIN_TRANSMITTER))), new Call[](0)
        );
    }

    /// @dev #28 end to end: a transceiver born knowing only the governor's home accepts the
    ///      governor's bootstrap through the provider's own callback, and the receiver it
    ///      creates is its owner. The sender is the default counterpart on a `Predetermined` home:
    ///      this transceiver's own address.
    function test_aBornConfiguredTransceiverAcceptsTheGovernorsBootstrap() public {
        address t = _deployBornConfigured(IChainRegistryRefs(address(_seeded(Provenance.Predetermined))), GOVERNOR, 0);
        address owner = TransceiverBase(payable(t)).owner();
        assertEq(owner.code.length, 0, "the owner does not exist yet");

        _deliverTo(t, t, _governorsBootstrap(owner));

        assertEq(ReceiverBase(payable(owner)).sourceTransmitter(), owner, "the bootstrap created the owner");
    }

    /// @dev #32: only the owner the bootstrap creates could set a counterpart, so a home whose
    ///      counterpart does not resolve at birth is refused rather than left unusable.
    function test_aGovernorHomeBelowPredeterminedIsRefusedAtBirth() public {
        ChainRegistry registry = _seeded(Provenance.Unique);
        vm.expectRevert(
            abi.encodeWithSelector(OutboundBase.NoCounterpartFor.selector, ChainKey.forEvm(ORIGIN_CHAIN_ID))
        );
        this.deployBornConfigured(IChainRegistryRefs(address(registry)));
    }

    function test_aSuspendedGovernorHomeIsRefusedAtBirth() public {
        ChainRegistry registry = _seeded(Provenance.Predetermined);
        bytes32 home = ChainKey.forEvm(ORIGIN_CHAIN_ID);
        registry.setSuspended(home, true);
        vm.expectRevert(abi.encodeWithSelector(TransceiverBase.ChainSuspended.selector, home));
        this.deployBornConfigured(IChainRegistryRefs(address(registry)));
    }

    address internal constant GOVERNOR = address(0x5165);

    /// @dev External so that an expected revert attaches to the deployment, not the first
    ///      contract `_deployBornConfigured` creates on the way.
    function deployBornConfigured(IChainRegistryRefs registry) external returns (address) {
        return _deployBornConfigured(registry, GOVERNOR, 0);
    }

    function _seeded(Provenance homeGrade) internal returns (ChainRegistry) {
        return new ChainRegistry(
            address(this),
            RegistrySeed({
                governorHome: Erc7930.encodeEvmChain(ORIGIN_CHAIN_ID),
                governorHomeGrade: homeGrade,
                providers: new ProviderSeed[](0)
            })
        );
    }

    /// @dev Sent from the default counterpart on a `Predetermined` home with no deployment record,
    ///      the transceiver's own address.
    function _governorsBootstrap(address owner) internal pure returns (bytes memory) {
        return Envelope.encodeBootstrap(GOVERNOR, bytes32(0), bytes32(uint256(uint160(owner))), new Call[](0));
    }

    function test_aBootstrapThroughTheProviderCreatesAConfiguredReceiver() public {
        bytes32 chainKey = _wire();
        TransceiverBase t = TransceiverBase(payable(_transceiver()));

        vm.expectEmit(true, true, true, true, address(t));
        emit InboundHandled(chainKey);
        _deliver(ORIGIN_TRANSCEIVER, _bootstrap());

        address receiver = t.predictCrossAccount(ACCOUNT_OWNER, ACCOUNT_SALT, chainKey);
        assertEq(ReceiverBase(payable(receiver)).sourceTransmitter(), ORIGIN_TRANSMITTER);
        _assertReceiverConfigured(receiver, ORIGIN_TRANSMITTER);
    }

    function test_anotherSenderOnTheOriginIsRefused() public {
        bytes32 chainKey = _wire();
        vm.expectRevert(_wrongSenderRevert(chainKey, address(0xBAD)));
        _deliver(address(0xBAD), _bootstrap());
    }

    /// @dev The report float is funded with a plain transfer (#17).
    function test_itAcceptsAPlainTransfer() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = _transceiver().call{value: 1 ether}("");
        assertTrue(ok);
    }

    function test_theFloatLeavesOnlyToTheTreasury() public {
        TransceiverBase t = TransceiverBase(payable(_transceiver()));
        address treasury = t.treasury();
        vm.deal(address(t), 1 ether);

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(TransceiverBase.NotTreasury.selector, address(0xBAD)));
        t.withdraw(1 ether);

        uint256 before = treasury.balance;
        vm.prank(treasury);
        t.withdraw(0.4 ether);
        assertEq(treasury.balance - before, 0.4 ether);
    }

    /// @dev C24 over configuration and a delivery.
    function test_noWriteLandsOnAnotherField() public {
        vm.startStateDiffRecording();
        _wire();
        _deliver(ORIGIN_TRANSCEIVER, _bootstrap());
        address[] memory accounts = new address[](1);
        accounts[0] = _transceiver();
        SlotReuse.assertNone(vm.stopAndReturnStateDiff(), accounts);
    }
}
