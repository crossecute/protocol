// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SlotReuse} from "test/protocols/SlotReuse.t.sol";
import {ProviderFixture, ProviderIdFixture, toBytes32} from "test/protocols/ProviderFixture.sol";
import {deployAccount} from "test/DeployCrossProxy.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {providerIdOf, ProviderChainId, IProviderIdTable} from "src/protocols/ProviderChainId.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {unseeded} from "test/RegistrySeed.sol";
import {ChainRegistry, RegistrySeed, ProviderSeed} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {Envelope} from "src/messaging/Envelope.sol";

/// @notice The wrapper every provider's transceiver harness exposes: a thin subclass of the
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

/// @dev The GATEWAY_ROLE every binding checks, read without an external call so an expected
///      revert is not consumed by it.
bytes32 constant GATEWAY_ROLE = keccak256("crossecute.role.GATEWAY");

/// @title ProviderSendSpec
/// @notice The properties every native provider binding's transceiver send path must satisfy,
///         independent of which provider it is. A provider's send suite inherits this and its
///         fixture; the test bodies run unchanged.
///
/// @dev `_sendMessage`/`_quoteMessage` differ only in how they translate an ERC-7930
///      recipient into the provider's own destination id and price the send; that a
///      configured destination resolves correctly, an unconfigured one reverts, and the quote
///      matches what the send actually pays is identical across LayerZero, CCIP, Hyperlane,
///      Wormhole, and OP Stack.
abstract contract ProviderSendSpec is ProviderFixture {
    address internal constant REMOTE_COUNTERPART = address(0xC0DE);

    ISendHarness internal harness;

    /// @notice Assert the provider mock recorded a send targeting the provider-native
    ///         destination `_configuredRecipient()` resolves to. This is where the translation
    ///         is checked.
    function _assertLastSendTargetedConfiguredDestination() internal view virtual;

    /// @notice A well-formed attribute the binding supports.
    function _supportedAttribute() internal view virtual returns (bytes memory);

    function setUp() public virtual {
        harness = ISendHarness(_deployTransceiver(_config(), 0));
        _configureRemote(address(harness), REMOTE_COUNTERPART);
    }

    function _configuredRecipient() internal pure returns (bytes memory) {
        return Erc7930.encodeEvm(REMOTE_CHAIN_ID, REMOTE_COUNTERPART);
    }

    /// @notice A well-formed recipient on a chain nothing has configured.
    function _unconfiguredRecipient() internal pure returns (bytes memory) {
        return Erc7930.encodeEvm(1, REMOTE_COUNTERPART);
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

    function test_unknownAttributeIsRefused() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(bytes4(0xdeadbeef), uint256(1));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        harness.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_malformedFirstAttributeIsReportedBeforeAnExtra() public {
        bytes[] memory attrs = new bytes[](2);
        attrs[0] = abi.encodePacked(bytes4(0xdeadbeef), uint256(1));
        attrs[1] = _supportedAttribute();
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        harness.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
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

    /// @dev A bootstrap sends `msg.value` less the protocol fee, so a binding that requires
    ///      `msg.value == value` reverts every bootstrap once a fee is configured.
    function test_sendSpendsExactlyValueEvenWhenLessThanMsgValue() public {
        _setProviderFee(0.01 ether);
        uint256 q = harness.quoteMessagePublic(_configuredRecipient(), "x");
        vm.deal(address(this), 2 * q);
        harness.sendMessagePublic{value: 2 * q}(_configuredRecipient(), "x", new bytes[](0), q);
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
/// @notice C12 (R2.3), for providers that price by payload length and carry the payload as
///         given (LayerZero, CCIP, Hyperlane; Wormhole wraps it and OP Stack does not price it).
abstract contract ProviderPayloadPricedSpec is ProviderFeeSpec {
    function _setProviderFeePerByte(uint256 perByte) internal virtual;

    /// @notice The payload the provider's mock was handed for the last send.
    function _lastSentBody() internal view virtual returns (bytes memory);

    function test_quoteIsTakenOverTheExactPayloadBytes() public {
        _setProviderFeePerByte(1 gwei);
        bytes memory longer = "a longer payload than the other one";
        uint256 short = harness.quoteMessagePublic(_configuredRecipient(), "x");
        uint256 long = harness.quoteMessagePublic(_configuredRecipient(), longer);
        assertGt(long, short);
        harness.sendMessagePublic{value: long}(_configuredRecipient(), longer, new bytes[](0), long);
        assertEq(_lastPaid(), long);
    }

    function test_sendForwardsThePayloadAndValueUnchanged() public {
        _setProviderFee(0.01 ether);
        vm.deal(address(this), 1 ether);
        harness.sendMessagePublic{value: 0.01 ether}(_configuredRecipient(), "payload", new bytes[](0), 0.01 ether);
        assertEq(_lastSentBody(), "payload");
        assertEq(_lastPaid(), 0.01 ether);
    }
}

/// @title ProviderIdTableSpec
/// @notice For transceivers with a provider id table: what every transmitter reads on each send, through
///         the same `providerIdOf` it calls.
abstract contract ProviderIdTableSpec is ProviderSendSpec, ProviderIdFixture {
    /// @notice The exact revert for a delivery from an origin id never set.
    function _unmappedOriginRevert(uint256 providerId) internal view virtual returns (bytes memory) {
        return abi.encodeWithSelector(ProviderChainId.UnknownProviderId.selector, providerId);
    }

    function test_transmittersReadTheConfiguredIdFromTheTransceiver() public {
        assertEq(providerIdOf(address(harness), _configuredRecipient()), _remoteProviderId());
        vm.expectRevert(
            abi.encodeWithSelector(ProviderChainId.NoProviderIdFor.selector, Erc7930.chainKey(_unconfiguredRecipient()))
        );
        providerIdOf(address(harness), _unconfiguredRecipient());
    }

    /// @dev C28 for the one setter a binding adds: repointing a chain's id would silently
    ///      redirect its future sends.
    function test_theTypedSetterIsWriteOnce() public {
        bytes32 chainKey = Erc7930.chainKey(_configuredRecipient());
        address owner = TransceiverBase(payable(address(harness))).owner();
        vm.prank(owner);
        _setProviderId(address(harness), chainKey, _remoteProviderId());
        vm.expectRevert(abi.encodeWithSelector(ProviderChainId.ProviderIdAlreadySet.selector, chainKey));
        vm.prank(owner);
        _setProviderId(address(harness), chainKey, _remoteProviderId() + 1);
    }

    /// @dev C5, transceiver side: a delivery whose origin the table does not map is refused.
    function test_aDeliveryFromAnUnmappedOriginIsRefused() public {
        vm.expectRevert(_unmappedOriginRevert(999));
        _deliver(address(harness), 999, toBytes32(REMOTE_COUNTERPART), "");
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
abstract contract ProviderTransmitterSpec is ProviderFixture {
    /// @notice A transmitter behind a proxy, initialized.
    function _transmitter() internal returns (address) {
        return deployAccount(
            _transmitterImplementation(),
            abi.encodeCall(OwnableTransmitter.initialize, (address(this), address(0xB0B), bytes32(0)))
        );
    }

    function test_inboundToATransmitterReverts() public {
        address transmitter = _transmitter();
        vm.expectRevert();
        _deliver(transmitter, _remoteProviderId(), toBytes32(address(0xABCD)), "");
    }
}

/// @notice Called from a receiver's bootstrap payload: fails unless the receiver already
///         lets `gateway` deliver.
contract ProviderConfiguredProbe {
    error GatewayNotYetConfigured(address gateway);

    function requireGateway(address gateway) external view {
        if (!IAccessControl(msg.sender).hasRole(GATEWAY_ROLE, gateway)) revert GatewayNotYetConfigured(gateway);
    }
}

/// @title ProviderReceiveSpec
/// @notice The properties every native provider binding's receive path must satisfy,
///         independent of which provider it is: the configured source is accepted, an
///         impersonator is rejected, an unconfigured origin is rejected, and a caller that is
///         not the provider's own gateway is rejected.
///
/// @dev LayerZero's peer check runs inside the vendored OApp SDK before this protocol's own
///      code sees the call, while Hyperlane/CCIP/Wormhole/OP Stack check `GATEWAY_ROLE` in
///      their own inbound entry point. This spec asserts only the observable property (revert,
///      or `Delivered`), never where the check runs.
abstract contract ProviderReceiveSpec is ProviderFixture {
    event Delivered(uint256 callCount);

    address internal constant SOURCE_TRANSMITTER = address(0xABCD);

    address internal receiver;

    function setUp() public virtual {
        receiver = _deployReceiver(new Call[](0));
    }

    /// @notice A new receiver behind a proxy whose initializer runs `calls` as its bootstrap
    ///         payload.
    function _deployReceiver(Call[] memory calls) internal returns (address) {
        return deployAccount(_receiverImplementation(), _initializeReceiver(SOURCE_TRANSMITTER, calls));
    }

    function _emptyPayload() internal pure returns (bytes memory) {
        return Payload.encodeCalls(new Call[](0));
    }

    function _deliverFrom(address sender) internal {
        _deliver(receiver, _remoteProviderId(), toBytes32(sender), _emptyPayload());
    }

    /// @notice Deliver a correctly-authenticated message from an origin this receiver was never
    ///         configured for. A receiver that keeps no origin state has no such case, and the
    ///         impersonator stands in.
    function _deliverFromUnconfiguredOrigin() internal virtual {
        _deliverFrom(address(0xBAD));
    }

    function test_theConfiguredSourceIsAccepted() public {
        vm.expectEmit(false, false, false, true, receiver);
        emit Delivered(0);
        _deliverFrom(SOURCE_TRANSMITTER);
    }

    function test_anImpersonatorIsRejected() public {
        vm.expectRevert();
        _deliverFrom(address(0xBAD));
    }

    function test_anUnconfiguredOriginIsRejected() public {
        vm.expectRevert();
        _deliverFromUnconfiguredOrigin();
    }

    function test_anythingButTheProvidersOwnGatewayIsRejected() public {
        vm.expectRevert();
        _deliverBypassingGateway(receiver, toBytes32(SOURCE_TRANSMITTER), _emptyPayload());
    }

    function test_theReceiverGrantsTheGatewayItsRole() public view {
        assertTrue(IAccessControl(receiver).hasRole(GATEWAY_ROLE, _gateway()));
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
        vm.prank(SOURCE_TRANSMITTER);
        ReceiverBase(payable(receiver)).revokeGateway(_gateway());
        vm.expectRevert();
        _deliverFrom(SOURCE_TRANSMITTER);
    }

    /// @dev C24 for the account, which holds the provider's delivery state beside its own.
    function test_aDeliveryWritesOverNoOtherField() public {
        vm.startStateDiffRecording();
        _deliverFrom(SOURCE_TRANSMITTER);
        address[] memory accounts = new address[](1);
        accounts[0] = receiver;
        SlotReuse.assertNone(vm.stopAndReturnStateDiff(), accounts);
    }
}

/// @title ProviderWideSenderSpec
/// @notice C10 (R4.3): a provider-reported sender wider than 20 bytes, whose low 20 bytes are
///         the configured source, is refused rather than truncated into it. For providers that
///         report the sender in more than 20 bytes (all but OP Stack).
abstract contract ProviderWideSenderSpec is ProviderReceiveSpec {
    /// @notice The exact revert expected, so the test cannot pass by failing for another reason.
    function _wideSenderRevert(bytes32 wide) internal view virtual returns (bytes memory) {
        return abi.encodeWithSelector(ProviderAddress.UnsupportedSender.selector, wide);
    }

    function test_aWideSenderIsRejectedNotTruncated() public {
        bytes32 wide = toBytes32(SOURCE_TRANSMITTER) | bytes32(uint256(1) << 200);
        vm.expectRevert(_wideSenderRevert(wide));
        _deliver(receiver, _remoteProviderId(), wide, _emptyPayload());
    }
}

/// @title ProviderGovernorHomeSpec
/// @notice #28: on any chain but the governor's home, the transceiver's owner is created by a
///         bootstrap from that home, so a binding with a provider id table names the home's id
///         at initialization rather than leaving it to an owner that does not exist yet.
abstract contract ProviderGovernorHomeSpec is ProviderIdFixture {
    function test_theGovernorHomeIdIsNamedAtInitialization() public {
        address t = _deployTransceiver(_config(), 7);
        assertEq(IProviderIdTable(t).providerIdFor(ChainKey.forEvm(1)), 7);
        assertEq(TransceiverBase(payable(t)).routeFor(ChainKey.forEvm(1)), Erc7930.encodeEvmChain(1), "and its route");
    }
}

/// @title ProviderInboundSpec
/// @notice What every binding's transceiver must satisfy on the way in: a bootstrap from a
///         configured origin, arriving through the provider's own path, creates a receiver
///         configured for that provider; a wrong sender is refused; and the float can be funded
///         and leaves only to the treasury.
/// @dev The plain variant only. zkSync and Tron variants fail closed at account creation on
///      Forge's EVM, so their suites pin their own overrides instead.
abstract contract ProviderInboundSpec is ProviderFixture {
    event InboundHandled(bytes32 chainKey);

    /// @dev The origin's transceiver as this one records it. `Unique`, so no parity check.
    address internal constant ORIGIN_TRANSCEIVER = address(0xC0DE);
    address internal constant ACCOUNT_OWNER = address(0xA11CE);
    bytes32 internal constant ACCOUNT_SALT = keccak256("account");
    address internal constant ORIGIN_TRANSMITTER = address(0x7A11);
    address internal constant GOVERNOR = address(0x5165);

    /// @notice The transceiver under test, emitting `InboundHandled(origin)` as it handles a
    ///         message.
    address internal transceiver;

    function setUp() public virtual {
        transceiver = _deployTransceiver(_config(), 0);
    }

    /// @notice The revert for a wrong sender: the base's by default.
    function _wrongSenderRevert(bytes32 chainKey, address) internal view virtual returns (bytes memory) {
        return abi.encodeWithSelector(TransceiverBase.NotCounterpart.selector, chainKey);
    }

    /// @notice The revert when `caller` calls the delivery entry point directly.
    function _bypassRevert(address caller) internal view virtual returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, GATEWAY_ROLE);
    }

    /// @notice R6: the receiver was configured for the provider before its payload ran.
    function _assertReceiverConfigured(address receiver, address) internal view virtual {
        assertTrue(IAccessControl(receiver).hasRole(GATEWAY_ROLE, _gateway()));
    }

    function _deliverTo(address to, address sender, bytes memory message) internal {
        _deliver(to, _remoteProviderId(), toBytes32(sender), message);
    }

    function _wire() internal returns (bytes32 chainKey) {
        TransceiverBase t = TransceiverBase(payable(transceiver));
        ChainRegistry registry = new ChainRegistry(address(this), unseeded());
        bytes32 provider = registry.addMessageProvider("under-test");
        chainKey = registry.addChainKey(Erc7930.encodeEvmChain(REMOTE_CHAIN_ID), Provenance.Unique);

        vm.startPrank(t.owner());
        t.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Unique);
        t.setCounterpart(chainKey, Erc7930.encodeEvm(REMOTE_CHAIN_ID, ORIGIN_TRANSCEIVER));
        t.setRoute(chainKey, Erc7930.encodeEvmChain(REMOTE_CHAIN_ID));
        vm.stopPrank();
        _configureRemote(transceiver, ORIGIN_TRANSCEIVER);
    }

    function _bootstrap() internal pure returns (bytes memory) {
        return Envelope.encodeBootstrap(ACCOUNT_OWNER, ACCOUNT_SALT, toBytes32(ORIGIN_TRANSMITTER), new Call[](0));
    }

    /// @notice The plain transceiver born knowing only the governor's home, `REMOTE_CHAIN_ID`:
    ///         `registry`, provider `keccak256("under-test")`, a `Unique` bar, and the
    ///         provider's id for that home, with no owner call afterwards.
    /// @dev External so that an expected revert attaches to the deployment, not the first
    ///      contract created on the way.
    function deployBornConfigured(IChainRegistryRefs registry) external returns (address) {
        TransceiverConfig memory c = _config();
        c.governorOwner = GOVERNOR;
        c.governorHome = Erc7930.encodeEvmChain(REMOTE_CHAIN_ID);
        c.chainRegistry = registry;
        c.messageProvider = keccak256("under-test");
        c.minCounterpartProvenance = Provenance.Unique;
        return _deployTransceiver(c, _remoteProviderId());
    }

    function _seeded(Provenance homeGrade) internal returns (ChainRegistry) {
        return new ChainRegistry(
            address(this),
            RegistrySeed({
                governorHome: Erc7930.encodeEvmChain(REMOTE_CHAIN_ID),
                governorHomeGrade: homeGrade,
                providers: new ProviderSeed[](0)
            })
        );
    }

    /// @dev #28 end to end: a transceiver born knowing only the governor's home accepts the
    ///      governor's bootstrap through the provider's own callback, and the receiver it
    ///      creates is its owner. The sender is the default counterpart on a `Predetermined`
    ///      home with no deployment record: this transceiver's own address.
    function test_aBornConfiguredTransceiverAcceptsTheGovernorsBootstrap() public {
        address t = this.deployBornConfigured(IChainRegistryRefs(address(_seeded(Provenance.Predetermined))));
        address owner = TransceiverBase(payable(t)).owner();
        assertEq(owner.code.length, 0, "the owner does not exist yet");

        _deliverTo(t, t, Envelope.encodeBootstrap(GOVERNOR, bytes32(0), toBytes32(owner), new Call[](0)));

        assertEq(ReceiverBase(payable(owner)).sourceTransmitter(), owner, "the bootstrap created the owner");
    }

    /// @dev #32: only the owner the bootstrap creates could set a counterpart, so a home whose
    ///      counterpart does not resolve at birth is refused rather than left unusable.
    function test_aGovernorHomeBelowPredeterminedIsRefusedAtBirth() public {
        ChainRegistry registry = _seeded(Provenance.Unique);
        vm.expectRevert(
            abi.encodeWithSelector(OutboundBase.NoCounterpartFor.selector, ChainKey.forEvm(REMOTE_CHAIN_ID))
        );
        this.deployBornConfigured(IChainRegistryRefs(address(registry)));
    }

    function test_aSuspendedGovernorHomeIsRefusedAtBirth() public {
        ChainRegistry registry = _seeded(Provenance.Predetermined);
        bytes32 home = ChainKey.forEvm(REMOTE_CHAIN_ID);
        registry.setSuspended(home, true);
        vm.expectRevert(abi.encodeWithSelector(TransceiverBase.ChainSuspended.selector, home));
        this.deployBornConfigured(IChainRegistryRefs(address(registry)));
    }

    function test_aBootstrapThroughTheProviderCreatesAConfiguredReceiver() public {
        bytes32 chainKey = _wire();
        TransceiverBase t = TransceiverBase(payable(transceiver));

        vm.expectEmit(true, true, true, true, address(t));
        emit InboundHandled(chainKey);
        _deliverTo(transceiver, ORIGIN_TRANSCEIVER, _bootstrap());

        address receiver = t.predictCrossAccount(ACCOUNT_OWNER, ACCOUNT_SALT, chainKey);
        assertEq(ReceiverBase(payable(receiver)).sourceTransmitter(), ORIGIN_TRANSMITTER);
        _assertReceiverConfigured(receiver, ORIGIN_TRANSMITTER);
    }

    function test_anotherSenderOnTheOriginIsRefused() public {
        bytes32 chainKey = _wire();
        vm.expectRevert(_wrongSenderRevert(chainKey, address(0xBAD)));
        _deliverTo(transceiver, address(0xBAD), _bootstrap());
    }

    /// @dev Only the provider may deliver, whatever the message says.
    function test_onlyTheGatewayDelivers() public {
        _wire();
        bytes memory message = _bootstrap();
        vm.expectRevert(_bypassRevert(address(0xBAD)));
        vm.prank(address(0xBAD));
        _deliverBypassingGateway(transceiver, toBytes32(ORIGIN_TRANSCEIVER), message);
    }

    /// @dev The report float is funded with a plain transfer (#17).
    function test_itAcceptsAPlainTransfer() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = transceiver.call{value: 1 ether}("");
        assertTrue(ok);
    }

    function test_theFloatLeavesOnlyToTheTreasury() public {
        TransceiverBase t = TransceiverBase(payable(transceiver));
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
        _deliverTo(transceiver, ORIGIN_TRANSCEIVER, _bootstrap());
        address[] memory accounts = new address[](1);
        accounts[0] = transceiver;
        SlotReuse.assertNone(vm.stopAndReturnStateDiff(), accounts);
    }
}

/// @title ProviderGatewayRoleSpec
/// @notice For transceivers whose provider holds `GATEWAY_ROLE` (all but LayerZero, where OApp
///         checks the endpoint itself): the initializer grants it, not the deployment
///         remembering to list it.
abstract contract ProviderGatewayRoleSpec is ProviderInboundSpec {
    function test_theGatewayHoldsItsRoleWithNoneListed() public view {
        assertTrue(IAccessControl(transceiver).hasRole(GATEWAY_ROLE, _gateway()));
    }
}

interface IReportHarness {
    function reportPublic(bytes32 home, address owner, bytes32 salt, address receiver) external;
}

/// @title ProviderZkSyncSpec
/// @notice A zkSync transceiver always diverges, so it reports each receiver it creates to the
///         account's home. The report is sent inside a delivery, at `msg.value == 0`, so it is
///         paid from the float, and any overpayment must return to the float, not the relayer.
abstract contract ProviderZkSyncSpec is ProviderIdFixture {
    address internal constant HOME_TRANSCEIVER = address(0xC0DE);

    address internal zk;

    /// @notice A new implementation of the zkSync transceiver, wrapped so `reportPublic` reaches
    ///         `_reportReceiver`.
    function _zkSyncImplementation() internal virtual returns (address);

    /// @notice Deploy `d` as the zkSync transceiver through the provider's deploy script.
    function _deployZkSync(TransceiverDeployment memory d, bytes32 accountBytecodeHash)
        internal
        virtual
        returns (address);

    /// @notice Assert the provider's mock recorded the last report addressed to
    ///         `HOME_TRANSCEIVER` on `REMOTE_CHAIN_ID`, refunding any excess to `zk`.
    function _assertReportSent() internal view virtual;

    function setUp() public virtual {
        zk = _deployZkSync(_deployment(_zkSyncImplementation(), _config()), keccak256("zksolc"));
        ChainRegistry registry = new ChainRegistry(address(this), unseeded());
        bytes32 provider = registry.addMessageProvider("under-test");
        bytes32 home = registry.addChainKey(Erc7930.encodeEvmChain(REMOTE_CHAIN_ID), Provenance.Unique);

        TransceiverBase t = TransceiverBase(payable(zk));
        vm.startPrank(t.owner());
        t.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Unique);
        t.setRoute(home, Erc7930.encodeEvmChain(REMOTE_CHAIN_ID));
        t.setCounterpart(home, Erc7930.encodeEvm(REMOTE_CHAIN_ID, HOME_TRANSCEIVER));
        vm.stopPrank();
        _configureRemote(zk, HOME_TRANSCEIVER);
    }

    function test_itAlwaysDiverges() public view {
        assertTrue(TransceiverBase(payable(zk)).addressesDiverge());
    }

    function test_aReportSpendsFromTheFloat() public {
        _setProviderFee(0.01 ether);
        vm.deal(zk, 1 ether);

        vm.prank(makeAddr("relayer"));
        IReportHarness(zk).reportPublic(ChainKey.forEvm(REMOTE_CHAIN_ID), address(0xA11CE), bytes32(0), address(0x2C));

        assertEq(zk.balance, 1 ether - _expectedQuoteFor(0.01 ether), "the quoted fee, paid from the float");
        _assertReportSent();
    }
}
