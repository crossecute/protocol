// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LzOftTransmitter} from "src/protocols/layerzero/LzOftTransmitter.sol";
import {LzOftMessage} from "src/protocols/layerzero/LzOftMessage.sol";
import {LzMessage} from "src/protocols/layerzero/LzMessage.sol";
import {ILzOftFactory} from "src/protocols/layerzero/ILzOftFactory.sol";
import {DeliveryGas} from "src/messaging/DeliveryGas.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {deployAccount} from "test/DeployCrossProxy.sol";
import {MockOft} from "test/protocols/layerzero/MockOft.sol";

/// @dev The factory's account-facing surface, with one destination per chain the test sets.
contract MockOftFactory is ILzOftFactory {
    struct Route {
        uint32 eid;
        address dstOft;
        bytes32[] proof;
    }

    bytes32 public destRoot = keccak256("root");
    uint32 public constant HOME_EID = 30255;
    mapping(bytes32 => Route) internal _routes;

    error NotInRoot(bytes32 chainKey);

    function setRoute(bytes32 chainKey, uint32 eid, address dstOft, bytes32[] memory proof) external {
        _routes[chainKey] = Route(eid, dstOft, proof);
    }

    function bootstrapRoute(address, bytes32 chainKey)
        external
        view
        returns (uint32, address, uint32, bytes32, bytes32[] memory)
    {
        Route memory r = _routes[chainKey];
        if (r.eid == 0) revert NotInRoot(chainKey);
        return (r.eid, r.dstOft, HOME_EID, destRoot, r.proof);
    }

    function reportsReceiver(bytes32) external pure returns (bool) {
        return false;
    }

    /// @dev Parity: the receiver sits at the calling account's address.
    function predictReceiver(bytes32, address, bytes32) external view returns (bytes memory) {
        return abi.encodePacked(msg.sender);
    }
}

contract LzOftTransmitterTest is Test {
    MockOft oft;
    MockOftFactory factory;
    LzOftTransmitter account;

    address owner = address(0xA11CE);
    bytes32 constant SALT = keccak256("acct");
    uint256 constant DEST = 42161;
    uint32 constant DEST_EID = 30110;
    address constant DST_OFT = address(0xD057);
    bytes32 destKey = ChainKey.forEvm(DEST);

    function setUp() public {
        oft = new MockOft(address(0xE9));
        oft.setPeer(DEST_EID, DST_OFT);
        factory = new MockOftFactory();
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("sibling");
        factory.setRoute(destKey, DEST_EID, DST_OFT, proof);

        account = LzOftTransmitter(
            payable(deployAccount(
                    address(new LzOftTransmitter()),
                    abi.encodeWithSignature(
                        "initialize(address,address,bytes32,address)", owner, address(factory), SALT, address(oft)
                    )
                ))
        );
        vm.deal(address(account), 1 ether);
    }

    function _calls() internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(address(0xCA11), 0, hex"abcd");
    }

    function _bootstrap() internal {
        vm.prank(owner);
        account.bootstrap(DEST, _calls(), new bytes[](0));
    }

    /* ================================= bootstrap =============================== */

    /// @dev The account is the `send` caller, so the destination reads it as `composeFrom`.
    function test_theBootstrapGoesThroughTheHomeOftFromTheAccount() public {
        uint256 quote = account.quoteBootstrap(DEST, _calls(), new bytes[](0));
        _bootstrap();

        assertEq(oft.sentLength(), 1);
        MockOft.Sent memory s = oft.sent(0);
        assertEq(s.from, address(account), "the account calls send");
        assertEq(s.value, quote, "pays its quote");
        assertEq(s.param.dstEid, DEST_EID);
        assertEq(s.param.to, bytes32(uint256(uint160(address(factory)))), "to the factory");
        assertEq(s.param.amountLD, 0, "no tokens");
        assertEq(s.param.minAmountLD, 0);
        assertEq(s.param.extraOptions, LzMessage.defaultComposeOptions(DeliveryGas.BOOTSTRAP));

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("sibling");
        bytes memory expected = LzOftMessage.encodeBootstrap(
            LzOftMessage.Bootstrap(
                owner, SALT, ChainKey.local(), factory.HOME_EID(), address(oft), factory.destRoot(), proof, _calls()
            )
        );
        assertEq(s.param.composeMsg, expected, "the fields the destination derives the account from");

        (uint32 eid, address dstOft) = account.destinationOf(destKey);
        assertEq(eid, DEST_EID);
        assertEq(dstOft, DST_OFT);
        assertTrue(account.isBootstrapped(destKey));
    }

    function test_aRePeeredHomeOftRefusesTheBootstrapAndItsQuote() public {
        oft.setPeer(DEST_EID, address(0xBAD));
        bytes memory err = abi.encodeWithSelector(
            LzOftMessage.PeerChanged.selector,
            DEST_EID,
            bytes32(uint256(uint160(DST_OFT))),
            bytes32(uint256(uint160(address(0xBAD))))
        );
        vm.expectRevert(err);
        account.quoteBootstrap(DEST, _calls(), new bytes[](0));
        vm.prank(owner);
        vm.expectRevert(err);
        account.bootstrap(DEST, _calls(), new bytes[](0));
    }

    function test_aChainTheFactoryDoesNotHoldIsRefused() public {
        bytes32 other = ChainKey.forEvm(10);
        vm.expectRevert(abi.encodeWithSelector(MockOftFactory.NotInRoot.selector, other));
        account.quoteBootstrap(10, _calls(), new bytes[](0));
    }

    /* ================================== Path A ================================= */

    function test_aMessageGoesToTheReceiverWithThePayloadAsTheCompose() public {
        _bootstrap();
        bytes memory recipient = account.recipientOn(DEST);
        bytes memory payload = Payload.encodeCalls(_calls());

        uint256 quote = account.quoteMessage(recipient, payload, new bytes[](0));
        vm.prank(owner);
        account.sendMessage(recipient, payload, new bytes[](0));

        MockOft.Sent memory s = oft.sent(1);
        assertEq(s.from, address(account));
        assertEq(s.value, quote);
        assertEq(s.param.dstEid, DEST_EID);
        assertEq(s.param.to, bytes32(uint256(uint160(address(account)))), "the receiver, at this address on parity");
        assertEq(s.param.composeMsg, payload);
        assertEq(s.param.extraOptions, LzMessage.defaultComposeOptions(DeliveryGas.PAYLOAD));
    }

    /// @dev The OFT's owner can re-peer after the bootstrap; the send and its quote both see it.
    function test_aRePeerAfterTheBootstrapRefusesMessages() public {
        _bootstrap();
        oft.setPeer(DEST_EID, address(0xBAD));
        bytes memory recipient = account.recipientOn(DEST);
        bytes memory payload = Payload.encodeCalls(_calls());

        vm.expectPartialRevert(LzOftMessage.PeerChanged.selector);
        account.quoteMessage(recipient, payload, new bytes[](0));
        vm.prank(owner);
        vm.expectPartialRevert(LzOftMessage.PeerChanged.selector);
        account.sendMessage(recipient, payload, new bytes[](0));
    }

    /* ============================== initialization ============================= */

    function test_thePlainInitializerIsRefused() public {
        LzOftTransmitter logic = new LzOftTransmitter();
        vm.expectRevert(LzOftTransmitter.UseLzOftInitializer.selector);
        logic.initialize(owner, address(factory), SALT);
    }

    function test_theHomeOftIsSet() public view {
        assertEq(account.homeOft(), address(oft));
        assertEq(account.transceiver(), address(factory));
    }

    function test_onlyTheOptionsAttributeIsSupported() public view {
        assertTrue(account.supportsAttribute(LzMessage.OPTIONS_ATTRIBUTE));
        assertFalse(account.supportsAttribute(bytes4(keccak256("crossecute.lz-oft.amount"))));
        assertFalse(account.supportsAttribute(bytes4(0xdeadbeef)));
    }
}
