// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {bootstrapPayload} from "test/Harness.sol";
import {MockTransmitter} from "test/Transport.t.sol";

/// @dev Hands every bootstrap back to the conduit, as `LzOftConduitFactory` does, with the
///      body as the message. It has no `bootstrap`, so reaching path B would revert.
contract HandBackTransceiver {
    function conduitBootstrap(bytes calldata route, address, bytes32, bytes calldata body)
        external
        view
        returns (bytes memory recipient, bytes memory message)
    {
        Erc7930.Interop memory io = Erc7930.parseStrict(route);
        return (Erc7930.encode(io.chainType, io.chainRef, abi.encodePacked(address(this))), body);
    }

    function reportsReceiver(bytes32) external pure returns (bool) {
        return false;
    }

    function predictReceiver(bytes32, address, bytes32) external view returns (bytes memory) {
        return abi.encodePacked(msg.sender);
    }
}

/// @dev Where the transceiver hands back a message, `bootstrap` and `quoteBootstrap` send and
///      price it through the conduit's own transport, as `sendMessage` does.
contract TransmitterConduitBootstrapTest is Test {
    HandBackTransceiver t;
    MockTransmitter conduit;

    address owner = address(0xA11CE);
    bytes32 constant SALT = keccak256("acct");
    uint256 constant DESTINATION = 42161;

    function setUp() public {
        t = new HandBackTransceiver();
        address at = address(0xC0DE);
        vm.etch(at, address(new MockTransmitter()).code);
        conduit = MockTransmitter(payable(at));
        conduit.initialize(owner, address(t), SALT);
        vm.deal(at, 1 ether);
    }

    function test_theQuoteIsTheConduitsPriceOfTheMessage() public view {
        uint256 quoted = conduit.quoteBootstrap(bootstrapPayload(DESTINATION, _calls()), new bytes[](0));
        assertEq(quoted, Payload.encodeCalls(_calls()).length * conduit.WEI_PER_BYTE());
    }

    function test_theSendGoesThroughTheConduitsTransportAndPaysTheQuote() public {
        bytes memory payload = bootstrapPayload(DESTINATION, _calls());
        uint256 quoted = conduit.quoteBootstrap(payload, new bytes[](0));
        vm.prank(owner);
        conduit.bootstrap(payload, new bytes[](0));

        assertEq(conduit.sentCount(), 1);
        assertEq(conduit.sentRecipient(), Erc7930.encodeEvm(DESTINATION, address(t)), "to the transceiver there");
        assertEq(conduit.sentPayload(), Payload.encodeCalls(_calls()), "the message handed back");
        assertEq(conduit.sentValue(), quoted, "paid its quote");
        assertTrue(conduit.isBootstrapped(ChainKey.forEvm(DESTINATION)));
    }

    function test_anUnfundedConduitCannotBootstrap() public {
        bytes memory payload = bootstrapPayload(DESTINATION, _calls());
        uint256 quoted = conduit.quoteBootstrap(payload, new bytes[](0));
        vm.deal(address(conduit), quoted - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TransmitterBase.InsufficientBalance.selector, quoted, quoted - 1));
        conduit.bootstrap(payload, new bytes[](0));
    }

    function _calls() internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(address(0xCA11), 0, "");
    }
}
