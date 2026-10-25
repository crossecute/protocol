// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {LzOftFactory} from "src/protocols/layerzero/LzOftFactory.sol";
import {LzOftTransmitter} from "src/protocols/layerzero/LzOftTransmitter.sol";
import {LzOftReceiver} from "src/protocols/layerzero/LzOftReceiver.sol";
import {LzOftMessage} from "src/protocols/layerzero/LzOftMessage.sol";
import {CrossAccounts} from "src/account/CrossAccounts.sol";
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
abstract contract LzOftFactoryBase is Test {
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

    LzOftFactory factory;
    MockLzEndpoint endpoint;
    MockOft oft;
    address homeOftAddress;

    /// @dev On each chain: the endpoint, then the OFT, from this test's nonce, so the home OFT
    ///      and the destination OFT get the same address only if the test makes them.
    function _chain(uint256 chainId, uint32 localEid) internal {
        vm.chainId(chainId);
        LzOftTransmitter t = new LzOftTransmitter{salt: bytes32(0)}();
        LzOftReceiver r = new LzOftReceiver{salt: bytes32(0)}();
        factory = new LzOftFactory{salt: bytes32(0)}(address(t), address(r));
        endpoint = new MockLzEndpoint{salt: bytes32(chainId)}();
        endpoint.setEid(localEid);
        oft = new MockOft{salt: bytes32(chainId)}(address(endpoint));
    }

    function _leaves(address dstOft) internal view returns (LzOftFactory.Leaf[] memory leaves) {
        leaves = new LzOftFactory.Leaf[](1);
        leaves[0] = LzOftFactory.Leaf(destKey, DEST_EID, dstOft);
    }

    function _calls(address sink) internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(sink, 0, abi.encodeCall(Sink.hit, ()));
    }
}

contract LzOftFactoryHomeTest is LzOftFactoryBase {
    address constant DST_OFT = address(0xD057);

    function setUp() public {
        _chain(HOME, HOME_EID);
        oft.setPeer(DEST_EID, DST_OFT);
    }

    function _create(LzOftFactory.Leaf[] memory leaves) internal returns (LzOftTransmitter) {
        vm.prank(owner);
        return LzOftTransmitter(payable(factory.createTransmitter(SALT, address(oft), leaves)));
    }

    function test_theAccountLandsWhereItsFieldsDerive() public {
        LzOftTransmitter account = _create(_leaves(DST_OFT));
        (,, bytes32 root,) = factory.bootstrapRoute(address(account), destKey);
        assertEq(address(account), factory.predictAccount(owner, SALT, homeKey, address(oft), root));
        assertEq(root, LzOftMessage.leaf(destKey, DEST_EID, DST_OFT), "one leaf is its own root");
        assertEq(account.owner(), owner);
        assertEq(account.homeOft(), address(oft));
        assertEq(account.transceiver(), address(factory));
        assertEq(account.accountSalt(), SALT);
    }

    /// @dev Every stored destination proves into the root the address binds, for any count.
    function testFuzz_everyDestinationProvesIntoTheRoot(uint8 count) public {
        uint256 n = bound(count, 1, 12);
        LzOftFactory.Leaf[] memory leaves = new LzOftFactory.Leaf[](n);
        for (uint256 i; i < n; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast) bounded above
            uint32 eid = uint32(40_000 + i);
            address dst = address(uint160(0xD000 + i));
            oft.setPeer(eid, dst);
            leaves[i] = LzOftFactory.Leaf(bytes32(i + 1), eid, dst);
        }
        LzOftTransmitter account = _create(leaves);

        bytes32 root;
        for (uint256 i; i < n; ++i) {
            (uint32 eid, address dst, bytes32 r, bytes32[] memory proof) =
                factory.bootstrapRoute(address(account), leaves[i].chainKey);
            root = r;
            assertEq(eid, leaves[i].eid);
            assertEq(dst, leaves[i].oft);
            assertTrue(MerkleProof.verify(proof, r, LzOftMessage.leaf(leaves[i].chainKey, eid, dst)), "proves");
        }
        assertEq(address(account), factory.predictAccount(owner, SALT, homeKey, address(oft), root));
    }

    function test_noDestinationsIsRefused() public {
        vm.expectRevert(LzOftFactory.NoDestinations.selector);
        _create(new LzOftFactory.Leaf[](0));
    }

    /// @dev Strictly ascending, which also refuses a chain listed twice.
    function test_unsortedOrRepeatedLeavesAreRefused() public {
        oft.setPeer(1, address(1));
        oft.setPeer(2, address(2));
        LzOftFactory.Leaf[] memory leaves = new LzOftFactory.Leaf[](2);
        leaves[0] = LzOftFactory.Leaf(bytes32(uint256(2)), 2, address(2));
        leaves[1] = LzOftFactory.Leaf(bytes32(uint256(1)), 1, address(1));
        vm.expectRevert(abi.encodeWithSelector(LzOftFactory.LeavesNotSorted.selector, 1));
        _create(leaves);

        leaves[1] = leaves[0];
        vm.expectRevert(abi.encodeWithSelector(LzOftFactory.LeavesNotSorted.selector, 1));
        _create(leaves);
    }

    function test_aLeafForThisChainIsRefused() public {
        oft.setPeer(HOME_EID, DST_OFT);
        LzOftFactory.Leaf[] memory leaves = new LzOftFactory.Leaf[](1);
        leaves[0] = LzOftFactory.Leaf(homeKey, HOME_EID, DST_OFT);
        vm.expectRevert(abi.encodeWithSelector(LzOftFactory.BadLeaf.selector, 0));
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
        vm.expectRevert(abi.encodeWithSelector(LzOftFactory.NotAnOft.selector, address(0xC0DE)));
        factory.createTransmitter(SALT, address(0xC0DE), _leaves(DST_OFT));
    }

    function test_theSameAccountCannotBeCreatedTwice() public {
        LzOftTransmitter account = _create(_leaves(DST_OFT));
        vm.expectRevert(
            abi.encodeWithSelector(CrossAccounts.CrossAccountExists.selector, owner, SALT, address(account))
        );
        _create(_leaves(DST_OFT));
    }

    function test_aChainNotListedHasNoRoute() public {
        LzOftTransmitter account = _create(_leaves(DST_OFT));
        vm.expectRevert(abi.encodeWithSelector(LzOftFactory.NotADestination.selector, address(account), homeKey));
        factory.bootstrapRoute(address(account), homeKey);
    }

    function test_onlyItsOwnAccountsArePredicted() public {
        LzOftTransmitter account = _create(_leaves(DST_OFT));
        vm.prank(address(account));
        assertEq(factory.predictReceiver(destKey, owner, SALT), abi.encodePacked(address(account)));
        vm.expectRevert(abi.encodeWithSelector(LzOftFactory.UnknownAccount.selector, address(this)));
        factory.predictReceiver(destKey, owner, SALT);
    }
}

contract LzOftFactoryDestinationTest is LzOftFactoryBase {
    address constant HOME_OFT = address(0x40F7);
    Sink sink;
    bytes32 root;
    address account;

    function setUp() public {
        _chain(DEST, DEST_EID);
        oft.setPeer(HOME_EID, HOME_OFT);
        sink = new Sink();
        root = LzOftMessage.leaf(destKey, DEST_EID, address(oft));
        account = factory.predictAccount(owner, SALT, homeKey, HOME_OFT, root);
    }

    function _bootstrap(bytes32 destRoot, bytes32[] memory proof) internal view returns (bytes memory) {
        return LzOftMessage.encodeBootstrap(
            LzOftMessage.Bootstrap(owner, SALT, homeKey, HOME_OFT, destRoot, proof, _calls(address(sink)))
        );
    }

    function _queue(MockOft from, address composeFrom, bytes memory compose) internal returns (bytes memory) {
        return from.receivePacket(HOME_EID, GUID, address(factory), composeFrom, compose);
    }

    function _run(MockOft from, bytes memory m) internal {
        vm.prank(EXECUTOR);
        endpoint.lzCompose(address(from), address(factory), GUID, 0, m, "");
    }

    function test_theBootstrapCreatesTheReceiverAtTheAccountsAddress() public {
        _run(oft, _queue(oft, account, _bootstrap(root, new bytes32[](0))));

        LzOftReceiver r = LzOftReceiver(payable(account));
        assertEq(r.sourceTransmitter(), account, "answers to the transmitter at the same address");
        assertEq(r.homeOrigin(), bytes32(uint256(HOME_EID)));
        assertEq(r.homeOft(), HOME_OFT);
        assertEq(r.localOft(), address(oft));
        assertEq(sink.hits(), 1, "ran the bootstrap calls");
    }

    /// @dev Native value the executor attaches reaches the account before its calls run.
    function test_valueReachesTheAccount() public {
        bytes memory m = _queue(oft, account, _bootstrap(root, new bytes32[](0)));
        vm.deal(EXECUTOR, 1 ether);
        vm.prank(EXECUTOR);
        endpoint.lzCompose{value: 1 ether}(address(oft), address(factory), GUID, 0, m, "");
        assertEq(account.balance, 1 ether);
        assertEq(address(factory).balance, 0);
    }

    /// @dev A contract outside the root queues a compose naming the victim's account.
    function test_anOftOutsideTheRootIsRefused() public {
        MockOft fake = new MockOft(address(endpoint));
        fake.setPeer(HOME_EID, HOME_OFT);
        bytes memory m = _queue(fake, account, _bootstrap(root, new bytes32[](0)));
        vm.expectRevert(
            abi.encodeWithSelector(LzOftFactory.NotInRoot.selector, LzOftMessage.leaf(destKey, DEST_EID, address(fake)))
        );
        _run(fake, m);
    }

    /// @dev The factory has no endpoint of its own; the one the claimed OFT uses must call.
    function test_aCallerOtherThanTheOftsEndpointIsRefused() public {
        bytes memory m = _queue(oft, account, _bootstrap(root, new bytes32[](0)));
        vm.expectRevert(abi.encodeWithSelector(LzOftFactory.NotTheEndpoint.selector, address(this)));
        factory.lzCompose(address(oft), GUID, m, EXECUTOR, "");
    }

    /// @dev The leaf binds the chain and its eid, so a root that lists this OFT for another
    ///      chain proves nothing here.
    function test_aLeafForAnotherChainIsRefused() public {
        bytes32 otherRoot = LzOftMessage.leaf(ChainKey.forEvm(10), 30111, address(oft));
        address other = factory.predictAccount(owner, SALT, homeKey, HOME_OFT, otherRoot);
        bytes memory m = _queue(oft, other, _bootstrap(otherRoot, new bytes32[](0)));
        vm.expectPartialRevert(LzOftFactory.NotInRoot.selector);
        _run(oft, m);
    }

    function test_aSenderOtherThanTheAccountIsRefused() public {
        bytes memory m = _queue(oft, address(0xBAD), _bootstrap(root, new bytes32[](0)));
        vm.expectRevert(abi.encodeWithSelector(LzOftFactory.NotTheAccount.selector, address(0xBAD), account));
        _run(oft, m);
    }

    function test_anOftThatNoLongerPeersTheHomeIsRefused() public {
        bytes memory m = _queue(oft, account, _bootstrap(root, new bytes32[](0)));
        oft.setPeer(HOME_EID, address(0xBAD));
        vm.expectPartialRevert(LzOftMessage.PeerChanged.selector);
        _run(oft, m);
    }

    /// @dev A root with a fake OFT in it passes every check, and creates the account that root
    ///      derives: never the one the real root derives.
    function test_aForgedRootCreatesAnotherAccount() public {
        MockOft fake = new MockOft(address(endpoint));
        fake.setPeer(HOME_EID, HOME_OFT);
        bytes32 forged = LzOftMessage.leaf(destKey, DEST_EID, address(fake));
        address elsewhere = factory.predictAccount(owner, SALT, homeKey, HOME_OFT, forged);
        _run(fake, _queue(fake, elsewhere, _bootstrap(forged, new bytes32[](0))));

        assertGt(elsewhere.code.length, 0);
        assertNotEq(elsewhere, account);
        assertEq(account.code.length, 0, "the real account is untouched");
    }

    function test_aSecondBootstrapIsRefused() public {
        _run(oft, _queue(oft, account, _bootstrap(root, new bytes32[](0))));
        bytes memory m = oft.receivePacket(
            HOME_EID, keccak256("again"), address(factory), account, _bootstrap(root, new bytes32[](0))
        );
        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(CrossAccounts.CrossAccountExists.selector, owner, SALT, account));
        endpoint.lzCompose(address(oft), address(factory), keccak256("again"), 0, m, "");
    }
}

/// @dev Home creates and sends; the destination receives the exact bytes the home OFT was given.
contract LzOftFactoryRoundTripTest is LzOftFactoryBase {
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
        LzOftTransmitter account = LzOftTransmitter(payable(factory.createTransmitter(SALT, homeOft, _leaves(dstOft))));
        vm.deal(address(account), 1 ether);
        Sink sink = new Sink{salt: bytes32(0)}();
        vm.prank(owner);
        account.bootstrap(DEST, _calls(address(sink)), new bytes[](0));
        MockOft.Sent memory boot = oft.sent(0);
        vm.prank(owner);
        bytes memory recipient = account.recipientOn(DEST);
        bytes memory payload = account.payloadForCalls(_calls(address(sink)));
        vm.prank(owner);
        account.sendMessage(recipient, payload, new bytes[](0));
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
        assertGt(address(account).code.length, 0, "the receiver is at the account's address");
        assertEq(destSink.hits(), 1);

        bytes32 guid2 = keccak256("pathA");
        address to = address(uint160(uint256(pathA.param.to)));
        assertEq(to, address(account));
        m = oft.receivePacket(HOME_EID, guid2, to, pathA.from, pathA.param.composeMsg);
        vm.prank(EXECUTOR);
        endpoint.lzCompose(address(oft), to, guid2, 0, m, "");
        assertEq(destSink.hits(), 2, "Path A ran through the receiver");
    }
}
