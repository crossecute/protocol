// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {LzOftConduitFactory} from "src/protocols/layerzero/LzOftConduitFactory.sol";
import {LzOftTransmitter} from "src/protocols/layerzero/LzOftTransmitter.sol";
import {LzOftReceiver} from "src/protocols/layerzero/LzOftReceiver.sol";
import {LzOftMessage} from "src/protocols/layerzero/LzOftMessage.sol";
import {CrossConduits} from "src/conduit/CrossConduits.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Call} from "src/messaging/Call.sol";
import {MockOft} from "test/protocols/layerzero/MockOft.sol";
import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";

contract Sink {
    uint256 public hits;

    function hit() external payable {
        ++hits;
    }
}

/// @dev Two chains in one EVM, each a state snapshot. The factory and its logic are deployed by
///      CREATE2 at fixed salts, so they land at one address on both, as Nick's proxy places
///      them; each copy reads its own `block.chainid` at deployment.
abstract contract LzOftConduitFactoryBase is Test {
    uint256 constant HOME = 8453;
    uint256 constant DEST = 42161;
    uint32 constant HOME_EID = 30184;
    uint32 constant DEST_EID = 30110;
    bytes32 constant SALT = keccak256("acct");
    bytes32 constant GUID = keccak256("guid");
    address constant EXECUTOR = address(0xE0EC);

    address owner = address(0xA11CE);
    bytes32 homeKey = ChainKey.forEvm(HOME);
    bytes32 destKey = ChainKey.forEvm(DEST);

    LzOftConduitFactory factory;
    MockLzEndpoint endpoint;
    MockOft oft;
    address homeOftAddress;

    /// @dev On each chain: the endpoint, then the OFT, from this test's nonce, so the home OFT
    ///      and the destination OFT get the same address only if the test makes them.
    function _chain(uint256 chainId, uint32 localEid) internal {
        vm.chainId(chainId);
        LzOftTransmitter t = new LzOftTransmitter{salt: bytes32(0)}();
        LzOftReceiver r = new LzOftReceiver{salt: bytes32(0)}();
        factory = new LzOftConduitFactory{salt: bytes32(0)}(address(t), address(r));
        endpoint = new MockLzEndpoint{salt: bytes32(chainId)}();
        endpoint.setEid(localEid);
        oft = new MockOft{salt: bytes32(chainId)}(address(endpoint));
    }

    function _leaves(address dstOft) internal view returns (LzOftConduitFactory.Leaf[] memory leaves) {
        leaves = new LzOftConduitFactory.Leaf[](1);
        leaves[0] = LzOftConduitFactory.Leaf(destKey, DEST_EID, dstOft);
    }

    function _calls(address sink) internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(sink, 0, abi.encodeCall(Sink.hit, ()));
    }
}

contract LzOftConduitFactoryHomeTest is LzOftConduitFactoryBase {
    address constant DST_OFT = address(0xD057);

    function setUp() public {
        _chain(HOME, HOME_EID);
        oft.setPeer(DEST_EID, DST_OFT);
    }

    function _create(LzOftConduitFactory.Leaf[] memory leaves) internal returns (LzOftTransmitter) {
        vm.prank(owner);
        return LzOftTransmitter(payable(factory.createTransmitter(SALT, address(oft), leaves)));
    }

    function test_theConduitLandsWhereItsFieldsDerive() public {
        LzOftTransmitter conduit = _create(_leaves(DST_OFT));
        (,, uint32 homeEid, bytes32 root,) = factory.bootstrapRoute(address(conduit), destKey);
        assertEq(homeEid, HOME_EID, "the home OFT's endpoint's eid");
        assertEq(address(conduit), factory.predictConduit(owner, SALT, homeKey, HOME_EID, address(oft), root));
        assertEq(root, LzOftMessage.leaf(destKey, DEST_EID, DST_OFT), "one leaf is its own root");
        assertEq(conduit.owner(), owner);
        assertEq(conduit.homeOft(), address(oft));
        assertEq(conduit.transceiver(), address(factory));
        assertEq(conduit.conduitSalt(), SALT);
    }

    /// @dev Every stored destination proves into the root the address binds, for any count.
    function testFuzz_everyDestinationProvesIntoTheRoot(uint8 count) public {
        uint256 n = bound(count, 1, 12);
        LzOftConduitFactory.Leaf[] memory leaves = new LzOftConduitFactory.Leaf[](n);
        for (uint256 i; i < n; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast) bounded above
            uint32 eid = uint32(40_000 + i);
            address dst = address(uint160(0xD000 + i));
            oft.setPeer(eid, dst);
            leaves[i] = LzOftConduitFactory.Leaf(bytes32(i + 1), eid, dst);
        }
        LzOftTransmitter conduit = _create(leaves);

        bytes32 root;
        for (uint256 i; i < n; ++i) {
            (uint32 eid, address dst,, bytes32 r, bytes32[] memory proof) =
                factory.bootstrapRoute(address(conduit), leaves[i].chainKey);
            root = r;
            assertEq(eid, leaves[i].eid);
            assertEq(dst, leaves[i].oft);
            assertTrue(MerkleProof.verify(proof, r, LzOftMessage.leaf(leaves[i].chainKey, eid, dst)), "proves");
        }
        assertEq(address(conduit), factory.predictConduit(owner, SALT, homeKey, HOME_EID, address(oft), root));
    }

    function test_noDestinationsIsRefused() public {
        vm.expectRevert(LzOftConduitFactory.NoDestinations.selector);
        _create(new LzOftConduitFactory.Leaf[](0));
    }

    /// @dev Strictly ascending, which also refuses a chain listed twice.
    function test_unsortedOrRepeatedLeavesAreRefused() public {
        oft.setPeer(1, address(1));
        oft.setPeer(2, address(2));
        LzOftConduitFactory.Leaf[] memory leaves = new LzOftConduitFactory.Leaf[](2);
        leaves[0] = LzOftConduitFactory.Leaf(bytes32(uint256(2)), 2, address(2));
        leaves[1] = LzOftConduitFactory.Leaf(bytes32(uint256(1)), 1, address(1));
        vm.expectRevert(abi.encodeWithSelector(LzOftConduitFactory.LeavesNotSorted.selector, 1));
        _create(leaves);

        leaves[1] = leaves[0];
        vm.expectRevert(abi.encodeWithSelector(LzOftConduitFactory.LeavesNotSorted.selector, 1));
        _create(leaves);
    }

    function test_aLeafForThisChainIsRefused() public {
        oft.setPeer(HOME_EID, DST_OFT);
        LzOftConduitFactory.Leaf[] memory leaves = new LzOftConduitFactory.Leaf[](1);
        leaves[0] = LzOftConduitFactory.Leaf(homeKey, HOME_EID, DST_OFT);
        vm.expectRevert(abi.encodeWithSelector(LzOftConduitFactory.BadLeaf.selector, 0));
        _create(leaves);
    }

    /// @dev No other chain shares the home's eid, and the destination factory refuses a compose
    ///      from it, so that bootstrap could never land.
    function test_aLeafWithTheHomesEidIsRefused() public {
        oft.setPeer(HOME_EID, DST_OFT);
        LzOftConduitFactory.Leaf[] memory leaves = new LzOftConduitFactory.Leaf[](1);
        leaves[0] = LzOftConduitFactory.Leaf(destKey, HOME_EID, DST_OFT);
        vm.expectRevert(abi.encodeWithSelector(LzOftConduitFactory.BadLeaf.selector, 0));
        _create(leaves);
    }

    function test_aLeafTheHomeOftDoesNotPeerIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LzOftMessage.PeerChanged.selector,
                DEST_EID,
                bytes32(uint256(uint160(address(0xBAD)))),
                bytes32(uint256(uint160(DST_OFT)))
            )
        );
        _create(_leaves(address(0xBAD)));
    }

    function test_aHomeOftWithoutAnEndpointIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LzOftConduitFactory.NotAnOft.selector, address(0xC0DE)));
        factory.createTransmitter(SALT, address(0xC0DE), _leaves(DST_OFT));
    }

    function test_theSameConduitCannotBeCreatedTwice() public {
        LzOftTransmitter conduit = _create(_leaves(DST_OFT));
        vm.expectRevert(
            abi.encodeWithSelector(CrossConduits.CrossConduitExists.selector, owner, SALT, address(conduit))
        );
        _create(_leaves(DST_OFT));
    }

    function test_aChainNotListedHasNoRoute() public {
        LzOftTransmitter conduit = _create(_leaves(DST_OFT));
        vm.expectRevert(abi.encodeWithSelector(LzOftConduitFactory.NotADestination.selector, address(conduit), homeKey));
        factory.bootstrapRoute(address(conduit), homeKey);
    }

    function test_onlyItsOwnConduitsArePredicted() public {
        LzOftTransmitter conduit = _create(_leaves(DST_OFT));
        vm.prank(address(conduit));
        assertEq(factory.predictReceiver(destKey, owner, SALT), abi.encodePacked(address(conduit)));
        vm.expectRevert(abi.encodeWithSelector(LzOftConduitFactory.UnknownConduit.selector, address(this)));
        factory.predictReceiver(destKey, owner, SALT);
    }
}

contract LzOftConduitFactoryDestinationTest is LzOftConduitFactoryBase {
    address constant HOME_OFT = address(0x40F7);
    Sink sink;
    bytes32 root;
    address conduit;

    function setUp() public {
        _chain(DEST, DEST_EID);
        oft.setPeer(HOME_EID, HOME_OFT);
        sink = new Sink();
        root = LzOftMessage.leaf(destKey, DEST_EID, address(oft));
        conduit = factory.predictConduit(owner, SALT, homeKey, HOME_EID, HOME_OFT, root);
    }

    function _bootstrap(bytes32 destRoot, bytes32[] memory proof) internal view returns (bytes memory) {
        return LzOftMessage.encodeBootstrap(
            LzOftMessage.Bootstrap(owner, SALT, homeKey, HOME_EID, HOME_OFT, destRoot, proof, _calls(address(sink)))
        );
    }

    function _queue(MockOft from, address composeFrom, bytes memory compose) internal returns (bytes memory) {
        return from.receivePacket(HOME_EID, GUID, address(factory), composeFrom, compose);
    }

    function _run(MockOft from, bytes memory m) internal {
        vm.prank(EXECUTOR);
        endpoint.lzCompose(address(from), address(factory), GUID, 0, m, "");
    }

    function test_theBootstrapCreatesTheReceiverAtTheConduitsAddress() public {
        _run(oft, _queue(oft, conduit, _bootstrap(root, new bytes32[](0))));

        LzOftReceiver r = LzOftReceiver(payable(conduit));
        assertEq(r.sourceTransmitter(), conduit, "answers to the transmitter at the same address");
        assertEq(r.homeOrigin(), bytes32(uint256(HOME_EID)));
        assertEq(r.homeOft(), HOME_OFT);
        assertEq(r.localOft(), address(oft));
        assertEq(sink.hits(), 1, "ran the bootstrap calls");
    }

    /// @dev Native value the executor attaches reaches the conduit before its calls run.
    function test_valueReachesTheConduit() public {
        bytes memory m = _queue(oft, conduit, _bootstrap(root, new bytes32[](0)));
        vm.deal(EXECUTOR, 1 ether);
        vm.prank(EXECUTOR);
        endpoint.lzCompose{value: 1 ether}(address(oft), address(factory), GUID, 0, m, "");
        assertEq(conduit.balance, 1 ether);
        assertEq(address(factory).balance, 0);
    }

    /// @dev A contract outside the root queues a compose naming the victim's conduit.
    function test_anOftOutsideTheRootIsRefused() public {
        MockOft fake = new MockOft(address(endpoint));
        fake.setPeer(HOME_EID, HOME_OFT);
        bytes memory m = _queue(fake, conduit, _bootstrap(root, new bytes32[](0)));
        vm.expectRevert(
            abi.encodeWithSelector(
                LzOftConduitFactory.NotInRoot.selector, LzOftMessage.leaf(destKey, DEST_EID, address(fake))
            )
        );
        _run(fake, m);
    }

    /// @dev The factory has no endpoint of its own; the one the claimed OFT uses must call.
    function test_aCallerOtherThanTheOftsEndpointIsRefused() public {
        bytes memory m = _queue(oft, conduit, _bootstrap(root, new bytes32[](0)));
        vm.expectRevert(abi.encodeWithSelector(LzOftConduitFactory.NotTheEndpoint.selector, address(this)));
        factory.lzCompose(address(oft), GUID, m, EXECUTOR, "");
    }

    /// @dev The leaf binds the chain and its eid, so a root that lists this OFT for another
    ///      chain proves nothing here.
    function test_aLeafForAnotherChainIsRefused() public {
        bytes32 otherRoot = LzOftMessage.leaf(ChainKey.forEvm(10), 30111, address(oft));
        address other = factory.predictConduit(owner, SALT, homeKey, HOME_EID, HOME_OFT, otherRoot);
        bytes memory m = _queue(oft, other, _bootstrap(otherRoot, new bytes32[](0)));
        vm.expectPartialRevert(LzOftConduitFactory.NotInRoot.selector);
        _run(oft, m);
    }

    function test_aSenderOtherThanTheConduitIsRefused() public {
        bytes memory m = _queue(oft, address(0xBAD), _bootstrap(root, new bytes32[](0)));
        vm.expectRevert(abi.encodeWithSelector(LzOftConduitFactory.NotTheConduit.selector, address(0xBAD), conduit));
        _run(oft, m);
    }

    /// @dev The conduit's own receiver on another chain, where the same OFT address is deployed
    ///      and peered, sends the conduit's bootstrap: `composeFrom` is the conduit there too, so
    ///      only the bound eid tells it from the home.
    function test_aComposeFromAnotherEidThanTheHomesIsRefused() public {
        uint32 elsewhere = 30111;
        oft.setPeer(elsewhere, HOME_OFT);
        bytes memory m =
            oft.receivePacket(elsewhere, GUID, address(factory), conduit, _bootstrap(root, new bytes32[](0)));
        vm.expectRevert(abi.encodeWithSelector(LzOftConduitFactory.NotTheHomeEid.selector, elsewhere, HOME_EID));
        _run(oft, m);
    }

    /// @dev The eid is part of the address: the same fields with another home eid are another
    ///      conduit.
    function test_theHomeEidIsBoundIntoTheAddress() public view {
        assertNotEq(factory.predictConduit(owner, SALT, homeKey, 30111, HOME_OFT, root), conduit);
    }

    function test_anOftThatNoLongerPeersTheHomeIsRefused() public {
        bytes memory m = _queue(oft, conduit, _bootstrap(root, new bytes32[](0)));
        oft.setPeer(HOME_EID, address(0xBAD));
        vm.expectPartialRevert(LzOftMessage.PeerChanged.selector);
        _run(oft, m);
    }

    /// @dev A root with a fake OFT in it passes every check, and creates the conduit that root
    ///      derives: never the one the real root derives.
    function test_aForgedRootCreatesAnotherConduit() public {
        MockOft fake = new MockOft(address(endpoint));
        fake.setPeer(HOME_EID, HOME_OFT);
        bytes32 forged = LzOftMessage.leaf(destKey, DEST_EID, address(fake));
        address elsewhere = factory.predictConduit(owner, SALT, homeKey, HOME_EID, HOME_OFT, forged);
        _run(fake, _queue(fake, elsewhere, _bootstrap(forged, new bytes32[](0))));

        assertGt(elsewhere.code.length, 0);
        assertNotEq(elsewhere, conduit);
        assertEq(conduit.code.length, 0, "the real conduit is untouched");
    }

    function test_aSecondBootstrapIsRefused() public {
        _run(oft, _queue(oft, conduit, _bootstrap(root, new bytes32[](0))));
        bytes memory m = oft.receivePacket(
            HOME_EID, keccak256("again"), address(factory), conduit, _bootstrap(root, new bytes32[](0))
        );
        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(CrossConduits.CrossConduitExists.selector, owner, SALT, conduit));
        endpoint.lzCompose(address(oft), address(factory), keccak256("again"), 0, m, "");
    }
}

/// @dev Home creates and sends; the destination receives the exact bytes the home OFT was given.
contract LzOftConduitFactoryRoundTripTest is LzOftConduitFactoryBase {
    function test_aBootstrapRoundTripsAndPathAFollows() public {
        uint256 start = vm.snapshotState();

        // The destination first, to learn its OFT's address for the home's leaf.
        _chain(DEST, DEST_EID);
        address dstOft = address(oft);
        vm.revertToState(start);

        _chain(HOME, HOME_EID);
        address homeOft = address(oft);
        oft.setPeer(DEST_EID, dstOft);
        vm.prank(owner);
        LzOftTransmitter conduit = LzOftTransmitter(payable(factory.createTransmitter(SALT, homeOft, _leaves(dstOft))));
        vm.deal(address(conduit), 1 ether);
        Sink sink = new Sink{salt: bytes32(0)}();
        vm.prank(owner);
        conduit.bootstrap(DEST, _calls(address(sink)), new bytes[](0));
        MockOft.Sent memory boot = oft.sent(0);
        vm.prank(owner);
        bytes memory recipient = conduit.recipientOn(DEST);
        bytes memory payload = conduit.payloadForCalls(_calls(address(sink)));
        vm.prank(owner);
        conduit.sendMessage(recipient, payload, new bytes[](0));
        MockOft.Sent memory pathA = oft.sent(1);
        vm.revertToState(start);

        _chain(DEST, DEST_EID);
        assertEq(address(oft), dstOft);
        oft.setPeer(HOME_EID, homeOft);
        Sink destSink = new Sink{salt: bytes32(0)}();

        bytes memory m = oft.receivePacket(
            HOME_EID, GUID, address(uint160(uint256(boot.param.to))), boot.from, boot.param.composeMsg
        );
        vm.prank(EXECUTOR);
        endpoint.lzCompose(address(oft), address(factory), GUID, 0, m, "");
        assertGt(address(conduit).code.length, 0, "the receiver is at the conduit's address");
        assertEq(destSink.hits(), 1);

        bytes32 guid2 = keccak256("pathA");
        address to = address(uint160(uint256(pathA.param.to)));
        assertEq(to, address(conduit));
        m = oft.receivePacket(HOME_EID, guid2, to, pathA.from, pathA.param.composeMsg);
        vm.prank(EXECUTOR);
        endpoint.lzCompose(address(oft), to, guid2, 0, m, "");
        assertEq(destSink.hits(), 2, "Path A ran through the receiver");
    }
}
