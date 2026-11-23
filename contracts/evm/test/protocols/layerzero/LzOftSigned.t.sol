// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LzOftConduitFactoryBase, Sink} from "test/protocols/layerzero/LzOftConduitFactory.t.sol";
import {LzOftConduitFactory} from "src/protocols/layerzero/LzOftConduitFactory.sol";
import {LzOftTransmitter} from "src/protocols/layerzero/LzOftTransmitter.sol";
import {LzOftReceiver} from "src/protocols/layerzero/LzOftReceiver.sol";
import {LzOftMessage} from "src/protocols/layerzero/LzOftMessage.sol";
import {ISignedTransmitter} from "src/messaging/outbound/ISignedTransmitter.sol";
import {ISignedReceiver} from "src/messaging/inbound/ISignedReceiver.sol";
import {Call} from "src/messaging/Call.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {DispatchLeaves} from "src/messaging/signed/DispatchLeaves.sol";
import {ExecutionLeaf, SafeTxEvidence} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {StubSafe, StubGuard} from "test/signed/StubSafe.sol";
import {Conduits} from "src/conduit/Conduits.sol";
import {Payload} from "src/messaging/Payload.sol";
import {SafeAuthorityGraph} from "src/messaging/signed/SafeAuthorityGraph.sol";
import {SafeSigs, Records} from "test/signed/SignedFixtures.sol";
import {MockOft} from "test/protocols/layerzero/MockOft.sol";
import {ILzOftConduitFactory} from "src/protocols/layerzero/ILzOftConduitFactory.sol";

/// @notice OFT transport with real cryptographic evidence, independently recreated destination state.
contract LzOftSignedTest is LzOftConduitFactoryBase {
    uint256 internal start;
    StubSafe internal safe;
    StubGuard internal guard;
    LzOftTransmitter internal transmitter;
    address internal dstOft;
    uint256 internal nonce;
    address internal child;

    struct Bundle {
        address conduit;
        address homeOft;
        bytes bootstrapWire;
        bytes messageWire;
        SafeTxEvidence message;
        bytes relayWire;
        SafeTxEvidence registration;
        ExecutionLeaf leaf;
        bytes32 graph;
    }

    function setUp() public {
        vm.warp(1_000_000);
        start = vm.snapshotState();
        _chain(DEST, DEST_EID);
        address destinationOft = address(oft);
        vm.revertToState(start);
        // Keep a reusable snapshot before either chain is created.
        start = vm.snapshotState();
        dstOft = destinationOft;
        _chain(HOME, HOME_EID);
        oft.setPeer(DEST_EID, dstOft);
        guard = StubGuard(address(0x600D));
        vm.etch(address(guard), address(new StubGuard()).code);
        guard.setAdvertises(true);
        safe = new StubSafe();
        address[] memory owners = new address[](2);
        owners[0] = vm.addr(1);
        owners[1] = vm.addr(2);
        safe.setOwners(owners, 2);
        safe.setGuard(address(guard));
        _select();
        vm.prank(address(safe));
        transmitter = LzOftTransmitter(payable(factory.createTransmitter(SALT, address(oft), _destinations(dstOft))));
        vm.deal(address(transmitter), 1 ether);
    }

    function _authorityGuard() internal pure override returns (address) {
        return address(0x600D);
    }

    function _multiSendCallOnly() internal pure override returns (address) {
        return address(0xCA11);
    }

    function _select() internal {
        guard.setSelection(
            address(safe), bytes32(uint256(1)), Records.graphHash(HOME, SafeAuthorityGraph.derive(address(safe)))
        );
    }

    function _evidence(bytes memory data) internal returns (SafeTxEvidence memory e) {
        e.signedSafeTx.safeTx.to = address(transmitter);
        e.signedSafeTx.safeTx.data = data;
        e.signedSafeTx.safeTx.nonce = nonce++;
        bytes32 hash = SafeHashes.transactionHash(e.signedSafeTx.safeTx, address(safe), HOME);
        if (child == address(0)) {
            e.signedSafeTx.signatures = SafeSigs.blob(SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(2)), hash);
        } else {
            bytes memory nested =
                SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(3)), SafeHashes.messageHash(abi.encode(hash), child, HOME));
            e.signedSafeTx.signatures =
                SafeSigs.blob(SafeSigs.two(SafeSigs.eoa(1), SafeSigs.nested(child, nested)), hash);
        }
    }

    function _exec(SafeTxEvidence memory e) internal {
        guard.stage(address(safe), e.signedSafeTx.safeTx, e.signedSafeTx.signatures);
        safe.exec(address(transmitter), 0, e.signedSafeTx.safeTx.data);
    }

    function _bootstrapEvidence() internal returns (SafeTxEvidence memory e) {
        return _bootstrapEvidence(new Call[](0));
    }

    function _bootstrapEvidence(Call[] memory calls) internal returns (SafeTxEvidence memory e) {
        bytes memory body =
            Records.bootstrap(address(guard), SafeAuthorityGraph.derive(address(safe)), abi.encode(calls));
        bytes memory payload = Payload.encodeBootstrap(Erc7930.encodeEvmChain(DEST), body);
        e = _evidence(abi.encodeCall(ISignedTransmitter.bootstrap, (payload, new bytes[](0))));
    }

    function _args(bytes memory data) internal pure returns (bytes memory args) {
        args = new bytes(data.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = data[i + 4];
        }
    }

    function _bootstrap() internal returns (bytes memory wire) {
        SafeTxEvidence memory e = _bootstrapEvidence();
        (bytes memory payload, bytes[] memory attributes) =
            abi.decode(_args(e.signedSafeTx.safeTx.data), (bytes, bytes[]));
        uint256 fee = transmitter.quoteBootstrap(payload, attributes);
        _exec(e);
        assertTrue(transmitter.isBootstrapped(destKey));
        MockOft.Sent memory sent = oft.sent(0);
        assertEq(sent.value, fee);
        assertEq(sent.from, address(transmitter), "OFT composeFrom must be the conduit");
        assertEq(sent.param.to, bytes32(uint256(uint160(address(factory)))));
        return sent.param.composeMsg;
    }

    function _bundle() internal returns (Bundle memory b) {
        b.conduit = address(transmitter);
        b.homeOft = address(oft);
        b.graph = Records.graphHash(HOME, SafeAuthorityGraph.derive(address(safe)));
        b.bootstrapWire = _bootstrap();
        b.message = _evidence(
            abi.encodeCall(
                transmitter.sendMessage, (Erc7930.encodeEvm(DEST, b.conduit), abi.encode(new Call[](0)), new bytes[](0))
            )
        );
        uint256 fee = transmitter.quoteMessageSigned(b.message);
        uint256 treasuryBefore = factory.treasury().balance;
        _exec(b.message);
        MockOft.Sent memory sent = oft.sent(1);
        assertEq(sent.value + sent.value / 10, fee);
        assertEq(factory.treasury().balance - treasuryBefore, sent.value / 10);
        assertEq(sent.from, b.conduit);
        b.messageWire = sent.param.composeMsg;
    }

    function _destination(Bundle memory b) internal returns (LzOftReceiver receiver) {
        vm.revertToState(start);
        _chain(DEST, DEST_EID);
        oft.setPeer(HOME_EID, b.homeOft);
        oft.deliver(HOME_EID, address(factory), bytes32(uint256(uint160(b.conduit))), b.bootstrapWire);
        receiver = LzOftReceiver(payable(b.conduit));
        assertEq(receiver.authorityGraph(), b.graph);
    }

    function test_signedCreationUsesSharedDerivation() public view {
        (,,, bytes32 root,) = factory.bootstrapRoute(address(transmitter), destKey);
        assertTrue(transmitter.isSigned());
        assertTrue(factory.isSigned(address(transmitter)));
        assertEq(
            address(transmitter), factory.predictConduit(address(safe), SALT, homeKey, HOME_EID, address(oft), root)
        );
    }

    /// @notice A guarded Safe whose owner does not answer as a Safe is refused at creation, as by
    ///         a registry transceiver, so no conduit is funded that its authority cannot describe.
    function test_aGuardedSafeWithAnOwnerThatIsNotASafeIsRefusedAtCreation() public {
        StubSafe other = new StubSafe();
        address[] memory owners = new address[](2);
        address notASafe = address(new Sink());
        (owners[0], owners[1]) = (vm.addr(1), notASafe);
        other.setOwners(owners, 2);
        other.setGuard(address(guard));
        ILzOftConduitFactory.Destination[] memory destinations = _destinations(dstOft);
        vm.prank(address(other));
        vm.expectRevert(abi.encodeWithSelector(SafeAuthorityGraph.NotASafe.selector, notASafe));
        factory.createTransmitter(SALT, address(oft), destinations);
    }

    /// @notice The factory keeps no mode record: it reads the flag the conduit holds.
    function test_theFactoryReportsTheModeTheConduitHolds() public {
        vm.prank(address(0xE0A));
        LzOftTransmitter unsignedTx = LzOftTransmitter(
            payable(factory.createTransmitter(keccak256("unsigned"), address(oft), _destinations(dstOft)))
        );
        assertFalse(unsignedTx.isSigned());
        assertFalse(factory.isSigned(address(unsignedTx)));
        assertFalse(factory.isSigned(address(this)), "an address the factory did not create");
        assertTrue(factory.isSigned(address(transmitter)));
    }

    /// @notice Each bootstrap builder serves only the mode its caller was created in.
    function test_eachBootstrapBuilderRefusesTheOtherModesConduit() public {
        vm.prank(address(0xE0A));
        LzOftTransmitter unsignedTx = LzOftTransmitter(
            payable(factory.createTransmitter(keccak256("unsigned"), address(oft), _destinations(dstOft)))
        );
        bytes memory route = Erc7930.encodeEvmChain(DEST);

        vm.prank(address(unsignedTx));
        vm.expectRevert(ILzOftConduitFactory.WrongBootstrapMode.selector);
        factory.signedConduitBootstrap(route, "");

        vm.prank(address(transmitter));
        vm.expectRevert(ILzOftConduitFactory.WrongBootstrapMode.selector);
        factory.conduitBootstrap(route, address(safe), SALT, abi.encode(new Call[](0)));

        vm.expectRevert(abi.encodeWithSelector(ILzOftConduitFactory.UnknownConduit.selector, address(this)));
        factory.signedConduitBootstrap(route, "");
    }

    /// @notice The signed builder derives the caller from the identity the conduit holds and
    ///         names the same envelope the conduit's own bootstrap carries.
    function test_theSignedBootstrapNamesTheConduitsOwnerAndSalt() public {
        bytes memory route = Erc7930.encodeEvmChain(DEST);
        vm.prank(address(transmitter));
        (, bytes memory message) = factory.signedConduitBootstrap(route, hex"1234");
        (, LzOftMessage.Bootstrap memory b,, bytes memory body) =
            abi.decode(message, (uint256, LzOftMessage.Bootstrap, uint256, bytes));
        assertEq(b.owner, address(safe));
        assertEq(b.salt, SALT);
        assertEq(body, hex"1234");
        (,,, bytes32 root,) = factory.bootstrapRoute(address(transmitter), destKey);
        assertEq(b.destRoot, root);
    }

    function test_signedBootstrapAndProviderDeliveryShareReplayWithDirectSubmission() public {
        Bundle memory b = _bundle();
        LzOftReceiver receiver = _destination(b);
        receiver.submitMessage(b.message);
        bytes32 hash =
            SafeHashes.transactionHash(b.message.signedSafeTx.safeTx, receiver.authorityRecords()[0].safe, HOME);
        assertTrue(receiver.isMessageExecuted(hash));
        oft.deliver(HOME_EID, b.conduit, bytes32(uint256(uint160(b.conduit))), b.messageWire);
        assertTrue(receiver.isMessageExecuted(hash));
    }

    function test_providerThenDirectExecutesCallsOnlyOnce() public {
        Bundle memory b = _bundle();
        // A deterministic sink can exist only on the destination; its address is signed at home.
        address target = address(0x5151);
        Call[] memory calls = _calls(target);
        b.message = _evidence(
            abi.encodeCall(
                transmitter.sendMessage, (Erc7930.encodeEvm(DEST, b.conduit), abi.encode(calls), new bytes[](0))
            )
        );
        _exec(b.message);
        b.messageWire = oft.sent(2).param.composeMsg;
        LzOftReceiver receiver = _destination(b);
        Sink implementation = new Sink();
        vm.etch(target, address(implementation).code);
        oft.deliver(HOME_EID, b.conduit, bytes32(uint256(uint160(b.conduit))), b.messageWire);
        receiver.submitMessage(b.message);
        assertEq(Sink(target).hits(), 1);
    }

    function test_bootstrapTransportFailureRollsBackAndSafeCanRetry() public {
        SafeTxEvidence memory e = _bootstrapEvidence();
        oft.setPeer(DEST_EID, address(0xBAD));
        guard.stage(address(safe), e.signedSafeTx.safeTx, e.signedSafeTx.signatures);
        vm.expectPartialRevert(LzOftMessage.PeerChanged.selector);
        safe.exec(address(transmitter), 0, e.signedSafeTx.safeTx.data);
        assertFalse(transmitter.isBootstrapped(destKey));
        (uint32 eid, address destination) = transmitter.destinationOf(destKey);
        assertEq(eid, 0);
        assertEq(destination, address(0));
        oft.setPeer(DEST_EID, dstOft);
        _exec(e);
        assertTrue(transmitter.isBootstrapped(destKey));
        assertEq(oft.sent(0).from, address(transmitter));
    }

    function test_signedBootstrapRepeatReverts() public {
        Bundle memory b = _bundle();
        _destination(b);
        vm.expectPartialRevert(Conduits.ConduitExists.selector);
        oft.deliver(HOME_EID, address(factory), bytes32(uint256(uint160(b.conduit))), b.bootstrapWire);
    }

    function test_unsignedPayloadCannotExecuteOnSignedReceiver() public {
        Bundle memory b = _bundle();
        _destination(b);
        vm.expectPartialRevert(ISignedReceiver.UnknownWire.selector);
        oft.deliver(HOME_EID, b.conduit, bytes32(uint256(uint160(b.conduit))), abi.encode(new Call[](0)));
    }

    function test_invalidSignatureRollsBackDeliveryAndReplayState() public {
        Bundle memory b = _bundle();
        LzOftReceiver receiver = _destination(b);
        b.message.signedSafeTx.signatures[0] ^= bytes1(uint8(1));
        (bool ok,) = address(receiver).call(abi.encodeCall(ISignedReceiver.submitMessage, (b.message)));
        assertFalse(ok);
        assertFalse(
            receiver.isMessageExecuted(
                SafeHashes.transactionHash(b.message.signedSafeTx.safeTx, receiver.authorityRecords()[0].safe, HOME)
            )
        );
    }

    function test_merkleRelayPricesFullWireRefundsRelayerAndSharesReplay() public {
        Bundle memory b = _bundle();
        b.leaf = ExecutionLeaf(
            Erc7930.encodeEvm(DEST, b.conduit),
            0,
            block.timestamp,
            block.timestamp + 1 days,
            abi.encode(new Call[](0)),
            new bytes[](0)
        );
        bytes32 root = DispatchLeaves.hash(b.leaf);
        b.registration = _evidence(abi.encodeCall(ISignedTransmitter.registerRoot, (root)));
        guard.publish(root);
        safe.exec(b.conduit, 0, b.registration.signedSafeTx.safeTx.data);
        address relayer = address(0xB0B);
        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        uint256 fee = transmitter.quoteLeaf(b.registration, b.leaf, new bytes32[](0));
        uint256 balance = b.conduit.balance;
        vm.prank(relayer);
        transmitter.relayLeaf{value: fee + 123}(b.registration, b.leaf, new bytes32[](0));
        assertEq(relayer.balance, 1 ether - fee);
        assertEq(b.conduit.balance, balance);
        MockOft.Sent memory sent = oft.sent(2);
        assertEq(sent.value, fee);
        assertEq(sent.refundTo, relayer);
        assertEq(sent.from, b.conduit);
        b.relayWire = sent.param.composeMsg;
        LzOftReceiver receiver = _destination(b);
        receiver.submitLeaf(b.registration, b.leaf, new bytes32[](0));
        oft.deliver(HOME_EID, b.conduit, bytes32(uint256(uint160(b.conduit))), b.relayWire);
        assertEq(receiver.nextNonce(), 1);
    }

    function test_directMessageDoesNotRequireSourceExecution() public {
        Bundle memory b = _bundle();
        b.message = _evidence(
            abi.encodeCall(
                transmitter.sendMessage,
                (Erc7930.encodeEvm(DEST, b.conduit), abi.encode(_calls(address(0x5151))), new bytes[](0))
            )
        );
        LzOftReceiver receiver = _destination(b);
        Sink implementation = new Sink();
        vm.etch(address(0x5151), address(implementation).code);
        receiver.submitMessage(b.message);
        assertEq(Sink(address(0x5151)).hits(), 1);
    }

    function test_nestedSafeAuthorityRoundTripsThroughOft() public {
        StubSafe nested = new StubSafe();
        address[] memory owners = new address[](1);
        owners[0] = vm.addr(3);
        nested.setOwners(owners, 1);
        nested.setGuard(address(guard));
        child = address(nested);
        owners = new address[](2);
        owners[0] = vm.addr(1);
        owners[1] = child;
        safe.setOwners(owners, 2);
        _select();
        Bundle memory b = _bundle();
        LzOftReceiver receiver = _destination(b);
        assertEq(receiver.authorityRecords().length, 2);
        oft.deliver(HOME_EID, b.conduit, bytes32(uint256(uint160(b.conduit))), b.messageWire);
        assertTrue(
            receiver.isMessageExecuted(
                SafeHashes.transactionHash(b.message.signedSafeTx.safeTx, receiver.authorityRecords()[0].safe, HOME)
            )
        );
    }

    function test_setupCallsExecuteOnceAndDuplicateBootstrapReverts() public {
        Bundle memory b;
        b.conduit = address(transmitter);
        b.homeOft = address(oft);
        b.graph = Records.graphHash(HOME, SafeAuthorityGraph.derive(address(safe)));
        _exec(_bootstrapEvidence(_calls(address(0x5151))));
        b.bootstrapWire = oft.sent(0).param.composeMsg;
        vm.revertToState(start);
        _chain(DEST, DEST_EID);
        oft.setPeer(HOME_EID, b.homeOft);
        Sink implementation = new Sink();
        vm.etch(address(0x5151), address(implementation).code);
        oft.deliver(HOME_EID, address(factory), bytes32(uint256(uint160(b.conduit))), b.bootstrapWire);
        vm.expectPartialRevert(Conduits.ConduitExists.selector);
        oft.deliver(HOME_EID, address(factory), bytes32(uint256(uint160(b.conduit))), b.bootstrapWire);
        assertEq(Sink(address(0x5151)).hits(), 1);
    }

    function test_bootstrapChainDomainCannotBeSubstituted() public {
        Bundle memory b = _bundle();
        (uint256 tag, LzOftMessage.Bootstrap memory header,, bytes memory body) =
            abi.decode(b.bootstrapWire, (uint256, LzOftMessage.Bootstrap, uint256, bytes));
        b.bootstrapWire = abi.encode(tag, header, HOME + 1, body);
        vm.revertToState(start);
        _chain(DEST, DEST_EID);
        oft.setPeer(HOME_EID, b.homeOft);
        vm.expectRevert(
            abi.encodeWithSelector(ILzOftConduitFactory.HomeChainMismatch.selector, HOME + 1, header.homeChainKey)
        );
        oft.deliver(HOME_EID, address(factory), bytes32(uint256(uint160(b.conduit))), b.bootstrapWire);
        assertEq(b.conduit.code.length, 0);
    }

    function test_quoteAndSendRejectUnselectedBootstrapAuthority() public {
        SafeTxEvidence memory e = _bootstrapEvidence();
        (bytes memory payload, bytes[] memory attributes) =
            abi.decode(_args(e.signedSafeTx.safeTx.data), (bytes, bytes[]));
        guard.setSelection(address(safe), bytes32(uint256(2)), bytes32(uint256(3)));
        vm.expectRevert(ISignedTransmitter.BootstrapAuthorityMismatch.selector);
        transmitter.quoteBootstrap(payload, attributes);
        guard.stage(address(safe), e.signedSafeTx.safeTx, e.signedSafeTx.signatures);
        vm.expectRevert(ISignedTransmitter.BootstrapAuthorityMismatch.selector);
        safe.exec(address(transmitter), 0, e.signedSafeTx.safeTx.data);
        assertFalse(transmitter.isBootstrapped(destKey));
    }

    function test_signedOwnershipCannotMove() public {
        vm.prank(address(safe));
        vm.expectRevert(ISignedTransmitter.OwnershipFixed.selector);
        transmitter.transferOwnership(address(0xBAD));
    }
}
