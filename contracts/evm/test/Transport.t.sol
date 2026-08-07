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
contract MockTransmitter is TransmitterBase {
    bytes32 public sentChainKey;
    bytes public sentPayload;
    uint256 public sentCount;
    uint256 public sentValue;

    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    bytes public sentProviderData;

    function _sendMessage(bytes32 chainKey, bytes memory payload, bytes memory providerData)
        internal
        override
    {
        sentChainKey = chainKey;
        sentPayload = payload;
        sentProviderData = providerData;
        sentValue = msg.value;
        ++sentCount;
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
    ///      DESTINATION, so the test picks it — a real spoke knows its own VM.
    bytes public sentProviderData;

    function _sendMessage(bytes32, bytes memory payload, bytes memory providerData)
        internal
        override
    {
        sentPayload = payload;
        sentProviderData = providerData;
        ++bootCount;
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

    /// @dev `Dispatched` carries the HASH — the bytes are already in calldata, so logging
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
    ///      of the payload — a three-call array needs more than a bare `commit` — so a
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
    ///      `Call[]`, so opaque elements sent there would arrive undeliverable — a payload
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
    ///      receiver runs — no commitment, no second transaction.
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

        address at = t.predictXSafeAccount(owner, SALT);
        vm.etch(at, address(new MockTransmitter()).code);
        acct = MockTransmitter(payable(at));
        acct.initialize(owner, address(t), SALT);
    }

    /// @dev A caller that is not the account `(owner, salt)` names cannot bootstrap it —
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
    ///      came from — so this is the last point that could catch it.
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
}

/// @dev No `_sendMessage` override, to exercise the default.
contract BareTransmitter is TransmitterBase {
    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }
}
