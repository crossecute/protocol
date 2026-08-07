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

    function _sendMessage(bytes32 chainKey, bytes memory payload) internal override {
        sentChainKey = chainKey;
        sentPayload = payload;
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
    address public bootOwner;
    bytes32 public bootSalt;
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

    function _sendMessage(bytes32, bytes memory payload) internal override {
        (bootOwner, bootSalt,) = this.peek(payload);
        ++bootCount;
    }

    function peek(bytes calldata m)
        external
        pure
        returns (address, bytes32, Call[] memory)
    {
        return Envelope.decodeBootstrap(m);
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
        MockTransceiver t = new MockTransceiver();
        t.initialize(address(this), address(new MockTransmitter()));

        // An account at the address that pair derives to.
        address account = t.predictXSafeAccount(owner, SALT);
        MockTransmitter acct = new MockTransmitter();
        vm.etch(account, address(acct).code);
        MockTransmitter(payable(account)).initialize(owner, address(t), SALT);

        vm.prank(owner);
        MockTransmitter(payable(account)).bootstrap(DEST, _calls());

        assertEq(t.bootCount(), 1);
        assertEq(t.bootOwner(), owner);
        assertEq(t.bootSalt(), SALT);
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
        t.bootstrap(ChainKey.forEvm(DEST), owner, SALT, _calls());
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
