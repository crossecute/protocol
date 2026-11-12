// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LzOftConduitFactoryBase, Sink} from "test/protocols/layerzero/LzOftConduitFactory.t.sol";
import {LzOftConduitFactory} from "src/protocols/layerzero/LzOftConduitFactory.sol";
import {LzOftTransmitter} from "src/protocols/layerzero/LzOftTransmitter.sol";
import {LzOftReceiver} from "src/protocols/layerzero/LzOftReceiver.sol";
import {LzOftMessage} from "src/protocols/layerzero/LzOftMessage.sol";
import {SignedTransmitter} from "src/messaging/outbound/SignedTransmitter.sol";
import {SignedReceiver} from "src/messaging/inbound/SignedReceiver.sol";
import {ISignedTransmitter} from "src/messaging/outbound/ISignedTransmitter.sol";
import {ISignedReceiver} from "src/messaging/inbound/ISignedReceiver.sol";
import {Call} from "src/messaging/Call.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {DispatchLeaves} from "src/messaging/signed/DispatchLeaves.sol";
import {
    BootstrapLeaf,
    ExecutionLeaf,
    SafeTxEvidence,
    SignedBootstrap
} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {StubSafe, StubGuard} from "test/signed/StubSafe.sol";
import {SafeSigs} from "test/signed/SignedFixtures.sol";
import {MockOft} from "test/protocols/layerzero/MockOft.sol";

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
        guard = new StubGuard();
        safe = new StubSafe();
        address[] memory owners = new address[](2);
        owners[0] = vm.addr(1);
        owners[1] = vm.addr(2);
        safe.setOwners(owners, 2);
        safe.setGuard(address(guard));
        vm.prank(address(safe));
        transmitter = LzOftTransmitter(payable(factory.createTransmitter(SALT, address(oft), _leaves(dstOft))));
        vm.deal(address(transmitter), 1 ether);
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
        BootstrapLeaf memory leaf = BootstrapLeaf(
            Erc7930.encodeEvm(DEST, address(transmitter)), block.timestamp, block.timestamp + 1 days, abi.encode(calls)
        );
        bytes memory payload = abi.encode(DispatchLeaves.hash(leaf), uint256(0), leaf, new bytes32[](0));
        e = _evidence(abi.encodeCall(ISignedTransmitter.bootstrap, (payload, new bytes[](0))));
    }

    function _bootstrap() internal returns (bytes memory wire) {
        SafeTxEvidence memory e = _bootstrapEvidence();
        (uint256 fee,) = transmitter.quoteSignedBootstrap(e);
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
        b.graph = transmitter.authorityGraph();
        b.bootstrapWire = _bootstrap();
        b.message = _evidence(
            abi.encodeCall(
                transmitter.sendMessage, (Erc7930.encodeEvm(DEST, b.conduit), abi.encode(new Call[](0)), new bytes[](0))
            )
        );
        uint256 fee = transmitter.quoteSignedMessage(b.message);
        _exec(b.message);
        MockOft.Sent memory sent = oft.sent(1);
        assertEq(sent.value, fee);
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

    function test_signedCreationBindsTheGraphAndPreservesPlainDerivation() public view {
        (,,, bytes32 root,) = factory.bootstrapRoute(address(transmitter), destKey);
        assertNotEq(transmitter.authorityGraph(), bytes32(0));
        assertEq(
            address(transmitter),
            factory.predictConduit(
                address(safe), SALT, homeKey, HOME_EID, address(oft), root, transmitter.authorityGraph()
            )
        );
        assertNotEq(
            address(transmitter), factory.predictConduit(address(safe), SALT, homeKey, HOME_EID, address(oft), root)
        );
        assertEq(
            factory.predictConduit(owner, SALT, homeKey, HOME_EID, address(oft), root, bytes32(0)),
            factory.predictConduit(owner, SALT, homeKey, HOME_EID, address(oft), root)
        );
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

    function test_bootstrapTransportFailureCanBeRetriedByAnyone() public {
        SafeTxEvidence memory e = _bootstrapEvidence();
        (, bytes memory body) = transmitter.quoteSignedBootstrap(e);
        oft.setPeer(DEST_EID, address(0xBAD));
        _exec(e);
        assertEq(transmitter.pendingBootstrap(destKey), keccak256(body));
        assertFalse(transmitter.isBootstrapped(destKey));
        oft.setPeer(DEST_EID, dstOft);
        transmitter.retryBootstrap(body);
        assertTrue(transmitter.isBootstrapped(destKey));
        assertEq(transmitter.pendingBootstrap(destKey), bytes32(0));
        assertEq(oft.sent(0).from, address(transmitter));
    }

    function test_signedBootstrapRepeatDoesNotRunSetupTwice() public {
        Bundle memory b = _bundle();
        _destination(b);
        oft.deliver(HOME_EID, address(factory), bytes32(uint256(uint160(b.conduit))), b.bootstrapWire);
        assertEq(LzOftReceiver(payable(b.conduit)).authorityGraph(), b.graph);
    }

    function test_plainPayloadCannotExecuteOnSignedReceiver() public {
        Bundle memory b = _bundle();
        _destination(b);
        vm.expectPartialRevert(SignedReceiver.UnknownWire.selector);
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
        uint256 fee = transmitter.quoteRelay(b.registration, b.leaf, new bytes32[](0));
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
        vm.prank(address(safe));
        transmitter = LzOftTransmitter(payable(factory.createTransmitter(SALT, address(oft), _leaves(dstOft))));
        vm.deal(address(transmitter), 1 ether);
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

    function test_setupCallsExecuteOnceAcrossBootstrapRetries() public {
        Bundle memory b;
        b.conduit = address(transmitter);
        b.homeOft = address(oft);
        b.graph = transmitter.authorityGraph();
        _exec(_bootstrapEvidence(_calls(address(0x5151))));
        b.bootstrapWire = oft.sent(0).param.composeMsg;
        vm.revertToState(start);
        _chain(DEST, DEST_EID);
        oft.setPeer(HOME_EID, b.homeOft);
        Sink implementation = new Sink();
        vm.etch(address(0x5151), address(implementation).code);
        oft.deliver(HOME_EID, address(factory), bytes32(uint256(uint160(b.conduit))), b.bootstrapWire);
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
            abi.encodeWithSelector(LzOftConduitFactory.HomeChainMismatch.selector, HOME + 1, header.homeChainKey)
        );
        oft.deliver(HOME_EID, address(factory), bytes32(uint256(uint160(b.conduit))), b.bootstrapWire);
        assertEq(b.conduit.code.length, 0);
    }

    function test_bootstrapAuthorityCannotBeSubstituted() public {
        Bundle memory b = _bundle();
        (uint256 tag, LzOftMessage.Bootstrap memory header, uint256 chainId, bytes memory body) =
            abi.decode(b.bootstrapWire, (uint256, LzOftMessage.Bootstrap, uint256, bytes));
        SignedBootstrap memory signedBody = abi.decode(body, (SignedBootstrap));
        signedBody.records[0].threshold = 1;
        b.bootstrapWire = abi.encode(tag, header, chainId, abi.encode(signedBody));
        vm.revertToState(start);
        _chain(DEST, DEST_EID);
        oft.setPeer(HOME_EID, b.homeOft);
        vm.expectPartialRevert(LzOftConduitFactory.NotTheConduit.selector);
        oft.deliver(HOME_EID, address(factory), bytes32(uint256(uint160(b.conduit))), b.bootstrapWire);
        assertEq(b.conduit.code.length, 0);
    }

    function test_signedOwnershipCannotMove() public {
        vm.prank(address(safe));
        vm.expectRevert(SignedTransmitter.OwnershipFixed.selector);
        transmitter.transferOwnership(address(0xBAD));
    }
}
