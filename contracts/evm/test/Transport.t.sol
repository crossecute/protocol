// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {ReceiverBase, ICommitFinalize} from "src/messaging/inbound/ReceiverBase.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainType} from "src/addressing/ChainType.sol";

/// @dev Records what reached the wire, so assertions are about the payload rather than a
///      provider's plumbing.
contract MockTransmitter is TransmitterBase, OwnableUpgradeable {
    bytes32 public sentChainKey;
    bytes public sentPayload;
    uint256 public sentCount;
    uint256 public sentValue;

    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    function _owner() internal view override returns (address) {
        return owner();
    }

    function _checkOwner() internal view override(TransmitterBase, OwnableUpgradeable) {
        OwnableUpgradeable._checkOwner();
    }

    bytes public sentProviderData;
    address public sentRefund;

    function _sendMessage(bytes32 chainKey, bytes memory payload, bytes memory providerData)
        internal
        override
    {
        sentChainKey = chainKey;
        sentPayload = payload;
        sentProviderData = providerData;
        sentValue = msg.value;
        sentRefund = _refundTo();
        ++sentCount;
    }

    /// @dev Priced per byte, which is what every real provider does, so a test can tell a
    ///      quote that read the payload from one that guessed at its size.
    uint256 public constant WEI_PER_BYTE = 7;

    function _quoteMessage(bytes32, bytes memory payload, bytes memory providerData)
        internal
        pure
        override
        returns (uint256)
    {
        return payload.length * WEI_PER_BYTE + providerData.length;
    }
}

/// @dev Exposes the inbound funnel a provider adapter would route into.
contract MockReceiver is ReceiverBase {
    function deliver(bytes calldata payload) external {
        _onMessage(payload);
    }
}

/// @dev Records the bootstrap the transmitter asked for.
/// @dev A spoke-free stand-in for the hub: `TransceiverBase` with the two routing hooks
///      answered directly, so `bootstrap`'s provenance lookup succeeds without a registry.
contract MockTransceiver is TransceiverBase, OwnableUpgradeable {
    bytes public sentPayload;
    uint256 public bootCount;
    address public bootRefund;

    address private _impl;

    function initialize(address owner_, address impl) external initializer {
        __Ownable_init(owner_);
        __TransceiverBase_init();
        _impl = impl;
    }

    function _checkAdmin() internal view override {
        _checkOwner();
    }

    function _accountImplementation() internal view override returns (address) {
        return _impl;
    }

    function _accountInitializer(address, bytes32, Call[] memory)
        internal
        pure
        override
        returns (bytes memory)
    {
        return "";
    }

    /// @dev Stands in for the registry lookup a real hub's `_route` performs.
    function _counterpartOn(bytes32) internal pure override returns (bytes memory) {
        return abi.encodePacked(address(0xC0DE));
    }

    function _routeTo(bytes32) internal pure override returns (bytes memory) {
        return abi.encode(uint32(30184));
    }

    function _handleInbound(bytes32, bytes calldata) internal override {}

    function _authenticateOrigin(bytes memory, bytes memory)
        internal
        pure
        override
        returns (bytes32)
    {
        return bytes32(0);
    }

    /// @dev Records the raw payload. Which decoder applies is a property of the
    ///      DESTINATION, so the test picks it: a real spoke knows its own VM.
    bytes public sentProviderData;

    function _sendMessage(bytes32, bytes memory payload, bytes memory providerData)
        internal
        override
    {
        sentPayload = payload;
        sentProviderData = providerData;
        bootRefund = _refundTo();
        ++bootCount;
    }

    /// @dev A different rate from the transmitter's, so a bootstrap quote that answered
    ///      from the account instead of delegating to here is visible in the number.
    uint256 public constant WEI_PER_BYTE = 11;

    function _quoteMessage(bytes32, bytes memory payload, bytes memory)
        internal
        pure
        override
        returns (uint256)
    {
        return payload.length * WEI_PER_BYTE;
    }
}

contract Sink {
    uint256 public total;

    function hit(uint256 n) external payable {
        total += n;
    }
}

contract TransportTest is Test {
    MockTransmitter transmitter;
    Sink sink;

    address owner = address(0xA11CE);
    uint256 constant DEST = 8453;
    bytes32 constant SALT = keccak256("acct");

    function setUp() public {
        transmitter = new MockTransmitter();
        transmitter.initialize(owner, address(0xBEEF), SALT);
        sink = new Sink();
    }

    function _calls() internal view returns (Call[] memory calls) {
        calls = new Call[](2);
        calls[0] = Call({target: address(sink), value: 0, data: abi.encodeCall(Sink.hit, (1))});
        calls[1] = Call({target: address(sink), value: 0, data: abi.encodeCall(Sink.hit, (2))});
    }

    /* ============================ path A: the payload ========================== */

    /// @dev THE WIRE CARRIES THE PAYLOAD, NOT A COMMITMENT. A call array is executed on
    ///      arrival; there is no digest and no second step unless the payload asks for one.
    function test_sendPutsTheCallArrayOnTheWire() public {
        Call[] memory calls = _calls();

        vm.prank(owner);
        transmitter.send(DEST, calls);

        assertEq(transmitter.sentCount(), 1);
        assertEq(transmitter.sentChainKey(), ChainKey.forEvm(DEST));
        assertEq(transmitter.sentPayload(), Payload.encodeCalls(calls));
    }

    /// @dev The fee rides with the send; the adapter reads `msg.value`.
    function test_sendForwardsTheBridgeFee() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        transmitter.send{value: 0.3 ether}(DEST, _calls());
        assertEq(transmitter.sentValue(), 0.3 ether);
    }

    /// @dev `Dispatched` carries the HASH: the bytes are already in calldata, so logging
    ///      them again would double the cost of every send.
    function test_dispatchedCarriesThePayloadHash() public {
        Call[] memory calls = _calls();

        vm.recordLogs();
        vm.prank(owner);
        transmitter.send(DEST, calls);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != OutboundBase.Dispatched.selector) continue;
            found = true;
            assertEq(logs[i].topics[1], ChainKey.forEvm(DEST));
            assertEq(logs[i].topics[2], keccak256(Payload.encodeCalls(calls)));
        }
        assertTrue(found);
    }

    /// @dev THE OPTIONS RIDE PER SEND, NOT AS CONFIGURATION. Destination gas is a property
    ///      of the payload (a three-call array needs more than a bare `commit`), so a
    ///      stored default would strand the first message that needed more.
    function test_providerDataTravelsPerSend() public {
        bytes memory opts = hex"0003010011010000000000000000000000000000ea60";

        vm.prank(owner);
        transmitter.send(DEST, _calls(), opts);
        assertEq(transmitter.sentProviderData(), opts);

        vm.prank(owner);
        transmitter.send(DEST, _calls());
        assertEq(transmitter.sentProviderData(), "", "the short form asks for the default");
    }

    /// @dev Every entry point carries it, in both payload forms and on both paths.
    function test_everyEntryPointCarriesProviderData() public {
        bytes memory opts = hex"beef";
        bytes memory sol = Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"01";

        vm.startPrank(owner);
        transmitter.sendTo(Erc7930.encodeEvmChain(DEST), _calls(), opts);
        assertEq(transmitter.sentProviderData(), opts, "sendTo typed");

        transmitter.sendTo(sol, elements, opts);
        assertEq(transmitter.sentProviderData(), opts, "sendTo opaque");
        vm.stopPrank();

        (MockTransceiver t, MockTransmitter acct) = _account();
        vm.startPrank(owner);
        acct.bootstrap(DEST, _calls(), opts);
        assertEq(t.sentProviderData(), opts, "bootstrap");

        acct.bootstrapTo(sol, elements, opts);
        assertEq(t.sentProviderData(), opts, "bootstrapTo opaque");
        vm.stopPrank();
    }

    function test_sendIsOwnerGated() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        transmitter.send(DEST, _calls());
    }

    function test_sendRejectsChainZero() public {
        vm.prank(owner);
        vm.expectRevert(OutboundBase.NoDestination.selector);
        transmitter.send(0, _calls());
    }

    /* ========================== path A: naming a chain ========================= */

    /// @dev `sendTo` is the escape hatch for destinations with no `uint256` chain id.
    function test_sendToNamesAChainByEnvelope() public {
        Call[] memory calls = _calls();

        vm.prank(owner);
        transmitter.sendTo(Erc7930.encodeEvmChain(DEST), calls);

        assertEq(transmitter.sentChainKey(), ChainKey.forEvm(DEST));
        assertEq(transmitter.sentPayload(), Payload.encodeCalls(calls));
    }

    /// @dev An account envelope is reduced to its chain, so a caller holding only a remote
    ///      address need not strip it by hand.
    function test_sendToAcceptsAnAccountEnvelope() public {
        vm.prank(owner);
        transmitter.sendTo(Erc7930.encodeEvm(DEST, address(0xBEEF)), _calls());
        assertEq(transmitter.sentChainKey(), ChainKey.forEvm(DEST));
    }

    /// @dev THE FORM FOLLOWS THE DESTINATION. `Call[]` is what an EVM receiver executes and
    ///      nothing else decodes it, so sending it to a chain that cannot is caught here
    ///      rather than on arrival.
    function test_typedPayloadIsRefusedForANonEvmDestination() public {
        bytes memory sol = Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");

        vm.prank(owner);
        vm.expectRevert(TransmitterBase.TypedPayloadToNonEvmDestination.selector);
        transmitter.sendTo(sol, _calls());
    }

    /// @dev THE MIRROR, AND IT MATTERS AS MUCH. An EVM receiver decodes `Call[]` and only
    ///      `Call[]`, so opaque elements sent there would arrive undeliverable: a payload
    ///      that crossed a bridge, cost a fee, and can never execute.
    function test_opaqueElementsAreRefusedForAnEvmDestination() public {
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"0102030405";

        vm.prank(owner);
        vm.expectRevert(TransmitterBase.OpaquePayloadToEvmDestination.selector);
        transmitter.sendTo(Erc7930.encodeEvmChain(DEST), elements);
    }

    /// @dev The portable form reaches it instead. The elements are that VM's own call
    ///      encoding and nothing here inspects one.
    function test_opaqueElementsReachANonEvmDestination() public {
        bytes memory sol = Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"0102030405";

        vm.prank(owner);
        transmitter.sendTo(sol, elements);

        assertEq(transmitter.sentChainKey(), ChainKey.fromIdentifier(sol));
        assertEq(transmitter.sentPayload(), Payload.encodeElements(elements));
    }

    function test_sendToRejectsANonCanonicalEnvelope() public {
        bytes memory bad =
            abi.encodePacked(uint16(1), ChainType.EIP155, uint8(2), hex"0001", uint8(0));

        vm.prank(owner);
        vm.expectRevert(Erc7930.NonMinimalChainRef.selector);
        transmitter.sendTo(bad, _calls());
    }

    /* ============================ path A: arrival ============================== */

    /// @dev END TO END. The payload the transmitter put on the wire is the payload the
    ///      receiver runs: no commitment, no second transaction.
    function test_aSentPayloadExecutesOnArrival() public {
        Call[] memory calls = _calls();

        vm.prank(owner);
        transmitter.send(DEST, calls);

        MockReceiver r = new MockReceiver();
        r.initialize(address(transmitter), new Call[](0));
        r.deliver(transmitter.sentPayload());

        assertEq(sink.total(), 3, "the array crossed and ran");
    }

    /// @dev DEFERRING IS THE SAME PATH. A payload whose one element calls the receiver's
    ///      own `commit` pins a hash instead of running anything; anyone supplies the
    ///      matching array later. Nothing on the wire distinguishes the two.
    function test_aDeferredPayloadPinsAHashInsteadOfRunning() public {
        MockReceiver r = new MockReceiver();
        r.initialize(address(transmitter), new Call[](0));

        Call[] memory later = _calls();
        bytes32 hash = Commitment.hashCalls(ChainKey.local(), later);

        Call[] memory deferred = new Call[](1);
        deferred[0] = transmitter.commitmentCall(address(r), hash);

        vm.prank(owner);
        transmitter.send(DEST, deferred);
        r.deliver(transmitter.sentPayload());

        assertEq(sink.total(), 0, "nothing ran on arrival");
        assertEq(r.commitment(), hash, "the payload pinned its own hash");

        vm.prank(address(0xF00D));
        r.finalize(later);
        assertEq(sink.total(), 3, "and anyone discharged it afterwards");
    }

    /* ================================= path B ================================== */

    /// @dev The transmitter states its owner and salt; the transceiver checks the pair
    ///      resolves back to the caller before anything crosses.
    function test_bootstrapStatesTheOwnerAndSalt() public {
        (MockTransceiver t, MockTransmitter acct) = _account();

        vm.prank(owner);
        acct.bootstrap(DEST, _calls());

        (address gotOwner, bytes32 gotSalt,) = _decodeTyped(t.sentPayload());
        assertEq(t.bootCount(), 1);
        assertEq(gotOwner, owner);
        assertEq(gotSalt, SALT);
    }

    /// @dev An account sitting at the address `(owner, SALT)` derives to, which is what
    ///      the transceiver checks `msg.sender` against.
    function _decodeTyped(bytes memory m)
        internal
        pure
        returns (address, bytes32, Call[] memory)
    {
        return abi.decode(m, (address, bytes32, Call[]));
    }

    function _account() internal returns (MockTransceiver t, MockTransmitter acct) {
        t = new MockTransceiver();
        t.initialize(address(this), address(new MockTransmitter()));

        address at = t.predictCrossAccount(owner, SALT);
        vm.etch(at, address(new MockTransmitter()).code);
        acct = MockTransmitter(payable(at));
        acct.initialize(owner, address(t), SALT);
    }

    /// @dev A caller that is not the account `(owner, salt)` names cannot bootstrap it,
    ///      so the only account anyone can stand up is the one that answers to them.
    function test_bootstrapRefusesACallerThatIsNotTheAccount() public {
        MockTransceiver t = new MockTransceiver();
        t.initialize(address(this), address(new MockTransmitter()));

        vm.expectRevert(
            abi.encodeWithSelector(
                TransceiverBase.NotTheAccount.selector, owner, SALT, address(this)
            )
        );
        t.bootstrap(ChainKey.forEvm(DEST), owner, SALT, _calls(), "");
    }

    /* ========================= path B: the two forms =========================== */

    /// @dev A NON-EVM CHAIN NEEDS ITS OWN BOOTSTRAP, because it needs its own payload
    ///      form. The account is stood up the same way; what differs is what it is handed.
    function test_bootstrapToCarriesOpaqueElementsToANonEvmChain() public {
        (MockTransceiver t, MockTransmitter acct) = _account();
        bytes memory sol = Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"0102030405";

        vm.prank(owner);
        acct.bootstrapTo(sol, elements);

        (address gotOwner, bytes32 gotSalt, bytes[] memory got) =
            abi.decode(t.sentPayload(), (address, bytes32, bytes[]));
        assertEq(t.bootCount(), 1);
        assertEq(gotOwner, owner);
        assertEq(gotSalt, SALT);
        assertEq(got[0], hex"0102030405", "and the elements crossed untouched");
    }

    /// @dev THE PAIRING IS ENFORCED WHERE THE CHAIN TYPE IS KNOWN. Downstream everything
    ///      speaks chainKeys, which are hashes and cannot be asked what chain type they
    ///      came from, so this is the last point that could catch it.
    function test_typedBootstrapIsRefusedForANonEvmChain() public {
        (, MockTransmitter acct) = _account();
        bytes memory sol = Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");

        vm.prank(owner);
        vm.expectRevert(TransmitterBase.TypedPayloadToNonEvmDestination.selector);
        acct.bootstrapTo(sol, _calls());
    }

    function test_opaqueBootstrapIsRefusedForAnEvmChain() public {
        (, MockTransmitter acct) = _account();
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"0102030405";

        vm.prank(owner);
        vm.expectRevert(TransmitterBase.OpaquePayloadToEvmDestination.selector);
        acct.bootstrapTo(Erc7930.encodeEvmChain(DEST), elements);
    }

    /// @dev The envelope-taking typed form reaches an EVM chain, same as the chain-id one.
    function test_bootstrapToReachesAnEvmChainWithTypedCalls() public {
        (MockTransceiver t, MockTransmitter acct) = _account();

        vm.prank(owner);
        acct.bootstrapTo(Erc7930.encodeEvmChain(DEST), _calls());
        assertEq(t.bootCount(), 1);
    }

    /// @dev Both forms prove the caller is the account, not just the typed one.
    function test_theOpaqueBootstrapAlsoChecksTheCaller() public {
        MockTransceiver t = new MockTransceiver();
        t.initialize(address(this), address(new MockTransmitter()));
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"01";

        vm.expectRevert(
            abi.encodeWithSelector(
                TransceiverBase.NotTheAccount.selector, owner, SALT, address(this)
            )
        );
        t.bootstrapElements(ChainKey.forEvm(DEST), owner, SALT, elements, "");
    }

    /* =============================== the authority ============================= */

    /// @dev THE BASE HAS NO OWNERSHIP OF ITS OWN. It states the requirement (`_owner` and
    ///      `_checkOwner`), and the concrete contract answers from whatever authority it
    ///      already has. That is what lets an account inherit a provider SDK that brings
    ///      its own `Ownable` without two ownership systems living in one contract.
    function test_theBaseContributesNoOwnershipSurface() public view {
        // `TransmitterBase` declares no owner storage and no `owner()`. The one reachable
        // here comes from the concrete contract.
        assertEq(transmitter.owner(), owner);
    }

    /// @dev And its modifier is `onlyAccountOwner`, not `onlyOwner`, two base classes
    ///      declaring one modifier name would force every derived contract to override it,
    ///      which is the same collision the seam exists to avoid, one level down.
    function test_theSeamGatesEveryEntryPoint() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert();
        transmitter.send(DEST, _calls());
        vm.expectRevert();
        transmitter.execute(_calls());
        vm.expectRevert();
        transmitter.bootstrap(DEST, _calls());
        vm.stopPrank();
    }

    /* ================================= preview ================================= */

    /// @dev THE TRANSMITTER PREVIEWS EVM DESTINATIONS AND NOTHING ELSE. The portable
    ///      overload that took a `Scheme` is gone: a preview frozen with the account can
    ///      only answer for primitives that existed when the account was created, so
    ///      non-EVM destinations are previewed through `ChainRegistry.commitmentFor`
    ///      instead. What remains still refuses a shape it cannot answer for, rather than
    ///      guessing: a preview you can compute for a message you cannot send is a trap.
    function test_previewRefusesTheShapeItNoLongerAnswersFor() public {
        bytes memory sol = Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");

        vm.expectRevert(TransmitterBase.TypedPayloadToNonEvmDestination.selector);
        transmitter.commitmentForChain(sol, _calls());
    }

    /// @dev The frozen surface is exactly one primitive wide, which is why it can never
    ///      go stale: every chain that executes `Call[]` hashes with keccak256, and
    ///      `ReceiverBase` enforces that same fold from bytecode frozen alongside it.
    function test_theEvmPreviewNeedsNoSchemeParameter() public view {
        Call[] memory calls = _sinkCallsFor(address(0));
        assertEq(
            transmitter.commitmentForChain(Erc7930.encodeEvmChain(block.chainid), calls),
            Commitment.hashCalls(ChainKey.local(), calls)
        );
    }

    /// @dev And the two legal shapes agree with what the receiver will recompute.
    function test_previewMatchesWhatTheReceiverRequires() public {
        Call[] memory calls = _sinkCallsFor(address(0));
        assertEq(
            transmitter.commitmentFor(block.chainid, calls),
            Commitment.hashCalls(ChainKey.local(), calls),
            "by chain id"
        );
        assertEq(
            transmitter.commitmentForChain(Erc7930.encodeEvmChain(block.chainid), calls),
            Commitment.hashCalls(ChainKey.local(), calls),
            "and by envelope"
        );
    }

    function _sinkCallsFor(address) internal view returns (Call[] memory) {
        return _calls();
    }

    /* ================================ the default ============================== */

    /// @dev A protocol that forgets to implement sending fails loudly on the first
    ///      message rather than reporting success for a payload that never left.
    function test_theDefaultSendReverts() public {
        BareTransmitter bare = new BareTransmitter();
        bare.initialize(owner, address(0xBEEF), bytes32(0));

        vm.prank(owner);
        vm.expectRevert(OutboundBase.SendNotImplemented.selector);
        bare.send(DEST, _calls());
    }

    /* ================================== quote ================================== */

    /// @dev THE SAME ARGUMENT AS `SendNotImplemented`, in the direction that matters more.
    ///      A quote that returned zero would be indistinguishable from a free message, and
    ///      the first thing anyone does with the answer is send exactly that much.
    function test_theDefaultQuoteReverts() public {
        BareTransmitter bare = new BareTransmitter();
        bare.initialize(owner, address(0xBEEF), bytes32(0));

        vm.expectRevert(OutboundBase.QuoteNotImplemented.selector);
        bare.quoteSend(DEST, _calls(), "");
    }

    /// @dev THE QUOTE PRICES THE EXACT BYTES THE SEND PUTS ON THE WIRE. Asserted against
    ///      the payload the send actually recorded, so a quote built from a second,
    ///      drifting encoder fails here rather than in production.
    function test_quotePricesTheExactPayloadTheSendCarries() public {
        Call[] memory calls = _calls();

        uint256 quoted = transmitter.quoteSend(DEST, calls, "");

        vm.prank(owner);
        transmitter.send(DEST, calls);

        assertEq(
            quoted,
            transmitter.sentPayload().length * transmitter.WEI_PER_BYTE(),
            "priced the bytes that left"
        );
    }

    /// @dev A LONGER PAYLOAD COSTS MORE, which is the property a caller is relying on. A
    ///      quote that ignored its argument would return one number for both.
    function test_quoteTracksThePayloadSize() public view {
        uint256 small = transmitter.quoteSend(DEST, _oneCall(), "");
        uint256 large = transmitter.quoteSend(DEST, _calls(), "");
        assertGt(large, small, "two calls cost more than one");
    }

    /// @dev THE OPTIONS ARE MOST OF WHAT A QUOTE PRICES, so they are an argument to it.
    function test_quoteReflectsProviderData() public view {
        uint256 bare = transmitter.quoteSend(DEST, _calls(), "");
        uint256 withOptions = transmitter.quoteSend(DEST, _calls(), hex"c0ffee");
        assertGt(withOptions, bare);
    }

    /// @dev IT IS A VIEW, WHICH IS THE WHOLE POINT OF IT. The only way a quote is ever
    ///      used is an `eth_call` before the send, so a mutable one is not a quote.
    function test_quoteIsStaticallyCallable() public view {
        (bool ok, bytes memory ret) = address(transmitter).staticcall(
            abi.encodeWithSignature(
                "quoteSend(uint256,(address,uint256,bytes)[],bytes)", DEST, _calls(), ""
            )
        );
        assertTrue(ok, "staticcall succeeded, so it wrote nothing");
        assertEq(abi.decode(ret, (uint256)), transmitter.quoteSend(DEST, _calls(), ""));
    }

    /// @dev UNGATED, UNLIKE THE SEND IT PRICES. A signer reviewing a payload before the
    ///      owner submits it has to be able to call this.
    function test_quoteIsNotOwnerGated() public {
        vm.prank(address(0xDEAD));
        transmitter.quoteSend(DEST, _calls(), "");
    }

    /// @dev THE BOOTSTRAP QUOTE ASKS THE TRANSCEIVER, because the transceiver is what
    ///      sends path B. The two mocks price at different rates, so an answer computed
    ///      locally would not match.
    function test_bootstrapQuoteDelegatesToTheTransceiver() public {
        MockTransceiver t = new MockTransceiver();
        t.initialize(address(this), address(new MockTransmitter()));

        MockTransmitter acct = new MockTransmitter();
        acct.initialize(owner, address(t), SALT);

        Call[] memory calls = _calls();
        uint256 quoted = acct.quoteBootstrap(DEST, calls, "");

        assertEq(
            quoted,
            Envelope.encodeBootstrap(owner, SALT, calls).length * t.WEI_PER_BYTE(),
            "the transceiver priced its own envelope"
        );
    }

    /// @dev A QUOTE IS TAKEN BEFORE THE ACCOUNT IT PRICES EXISTS, so it cannot carry
    ///      `bootstrap`'s "you must BE the account" check. There is nothing to protect on
    ///      a view that spends nothing.
    function test_bootstrapQuoteDoesNotRequireTheCallerToBeTheAccount() public {
        MockTransceiver t = new MockTransceiver();
        t.initialize(address(this), address(new MockTransmitter()));

        vm.prank(address(0xDEAD));
        uint256 quoted = t.quoteBootstrap(
            ChainKey.forEvm(DEST), owner, SALT, _calls(), ""
        );
        assertGt(quoted, 0);
    }

    /// @dev A RECEIVER HAS NO QUOTE SURFACE, AND THAT IS STRUCTURAL RATHER THAN GATED. It
    ///      does not inherit `OutboundBase` at all, so there is no seam to leave
    ///      unimplemented and no selector to reach: a receiver never sends, so pricing a
    ///      send from one would be pricing a message that has no path.
    function test_aReceiverExposesNoQuote() public {
        MockReceiver r = new MockReceiver();
        r.initialize(address(transmitter), new Call[](0));

        (bool ok,) = address(r).staticcall(
            abi.encodeWithSignature(
                "quoteSend(uint256,(address,uint256,bytes)[],bytes)", DEST, _calls(), ""
            )
        );
        assertFalse(ok, "no such function on a receiver");
    }

    /* ================================== refund ================================= */

    /// @dev THE PARTY WHO OVERPAID IS THE PARTY WHO GETS IT BACK. On path A the sender is
    ///      the owner, because `send` is owner-gated, so the remainder goes to the wallet
    ///      that signed and funded the message.
    function test_pathARefundsToTheOwner() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        transmitter.send{value: 0.3 ether}(DEST, _calls());
        assertEq(transmitter.sentRefund(), owner);
    }

    /// @dev ON PATH B IT IS THE ACCOUNT, AND NEVER THE TRANSCEIVER. This is the one this
    ///      has to get right: a shared transceiver refunding to itself would pool every
    ///      user's excess into infrastructure with no per-user way out. `bootstrap` refuses
    ///      any caller that is not the account, so the transceiver cannot be its own
    ///      caller and cannot be the refund target.
    function test_pathBRefundsToTheAccountNotTheTransceiver() public {
        (MockTransceiver t, MockTransmitter acct) = _account();

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        acct.bootstrap{value: 0.2 ether}(DEST, _calls());

        assertEq(t.bootRefund(), address(acct), "the account that asked for the message");
        assertTrue(t.bootRefund() != address(t), "never the shared transceiver");
    }

    /// @dev A REFUND IS A PLAIN VALUE TRANSFER, so the account has to be able to take one.
    ///      Without `receive` on the transmitter the refund reverts and takes the bootstrap
    ///      with it, which is the one message that cannot be retried cheaply.
    function test_theAccountCanReceiveARefund() public {
        (, MockTransmitter acct) = _account();

        vm.deal(address(this), 1 ether);
        (bool ok,) = payable(address(acct)).call{value: 0.1 ether}("");
        assertTrue(ok, "the transmitter accepts a refunded fee");
        assertEq(address(acct).balance, 0.1 ether);
    }

    function _oneCall() internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] =
            Call({target: address(sink), value: 0, data: abi.encodeCall(Sink.hit, (1))});
    }
}

/// @dev No `_sendMessage` override, to exercise the default.
contract BareTransmitter is TransmitterBase, OwnableUpgradeable {
    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    function _owner() internal view override returns (address) {
        return owner();
    }

    function _checkOwner() internal view override(TransmitterBase, OwnableUpgradeable) {
        OwnableUpgradeable._checkOwner();
    }
}
