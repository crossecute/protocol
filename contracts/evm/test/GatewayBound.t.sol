// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {GatewayBound} from "src/messaging/GatewayBound.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {LzReceiver} from "src/protocols/layerzero/LzReceiver.sol";
import {LzTransmitter} from "src/protocols/layerzero/LzTransmitter.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @dev One declaration, both directions. The gateway is a constructor argument so a test
///      can point the two halves at the same address and see them agree.
contract BoundReceiver is ReceiverBase {
    address public immutable gateway;

    constructor(address g) {
        gateway = g;
    }

    function _isAuthorizedGateway(address a) internal view override returns (bool) {
        return a == gateway;
    }
}

contract BoundTransmitter is TransmitterBase, OwnableUpgradeable {
    address public immutable gateway;

    constructor(address g) {
        gateway = g;
    }

    function initialize(address o, address t, bytes32 s) external initializer {
        __Ownable_init(o);
        __TransmitterBase_init(o, t, s);
    }

    function _owner() internal view override returns (address) {
        return owner();
    }

    function _checkOwner() internal view override(TransmitterBase, OwnableUpgradeable) {
        OwnableUpgradeable._checkOwner();
    }

    function _isAuthorizedGateway(address a) internal view override returns (bool) {
        return a == gateway;
    }

    /// @dev Stands in for what a binding's `_sendMessage` should do before it calls out.
    function assertGateway(address a) external view {
        _requireAuthorizedGateway(a);
    }
}

/// @notice The seam both halves answer from.
///
/// @dev THE POINT IS THAT THERE IS ONE ANSWER. A contract accepting deliveries from one
///      address while sending through another would be trusting two transports and
///      authenticating against one, and only a message from the second would ever reveal it.
contract GatewayBoundTest is Test {
    address constant GATEWAY = address(0x6A7EAA7);
    address constant IMPOSTOR = address(0xBAD);
    address owner = address(0xA11CE);

    BoundReceiver receiver;
    BoundTransmitter transmitter;

    function setUp() public {
        receiver = new BoundReceiver(GATEWAY);
        receiver.initialize(address(0xB0B), new Call[](0));

        transmitter = new BoundTransmitter(GATEWAY);
        transmitter.initialize(owner, address(0xC0DE), bytes32(0));
    }

    /// @dev THE INBOUND HALF, which was untested before the seam was shared: this is one of
    ///      the two checks standing in front of an `external` entry point.
    function test_aReceiverRefusesADeliveryFromAnyoneElse() public {
        bytes memory sender = Erc7930.encodeEvm(1, address(0xB0B));
        bytes memory payload = Payload.encodeCalls(new Call[](0));

        vm.prank(IMPOSTOR);
        vm.expectRevert(
            abi.encodeWithSelector(GatewayBound.NotAuthorizedGateway.selector, IMPOSTOR)
        );
        receiver.receiveMessage(bytes32(0), sender, payload);
    }

    /// @dev The sender is `sourceTransmitter`, not the receiver's own address: the two
    ///      differ wherever CREATE2 does, and the stored fact is what is compared.
    function test_aReceiverAcceptsItsOwnGateway() public {
        bytes memory sender = Erc7930.encodeEvm(1, address(0xB0B));
        bytes memory payload = Payload.encodeCalls(new Call[](0));

        vm.prank(GATEWAY);
        receiver.receiveMessage(bytes32(0), sender, payload);
    }

    /// @dev THE OUTBOUND HALF. The base cannot call it for a binding, since only the binding
    ///      knows which address it is about to reach, but it answers the same question so a
    ///      binding that asserts before sending cannot drift from what its receiver enforces.
    function test_theOutboundHalfAnswersTheSameQuestion() public {
        transmitter.assertGateway(GATEWAY);

        vm.expectRevert(
            abi.encodeWithSelector(GatewayBound.NotAuthorizedGateway.selector, IMPOSTOR)
        );
        transmitter.assertGateway(IMPOSTOR);
    }

    /// @dev And both halves are readable, so an operator can check a deployment agrees
    ///      without sending anything.
    function test_bothHalvesAreReadableAndAgree() public view {
        assertTrue(receiver.isAuthorizedGateway(GATEWAY));
        assertTrue(transmitter.isAuthorizedGateway(GATEWAY));
        assertFalse(receiver.isAuthorizedGateway(IMPOSTOR));
        assertFalse(transmitter.isAuthorizedGateway(IMPOSTOR));
    }

    /// @dev EVERY SHIPPED LAYERZERO CONTRACT REFUSES EVERYTHING, because no SDK is bound.
    ///      That is the honest default: a base that guessed an endpoint address would be
    ///      worse than one that accepts nothing, and it means the absence fails loudly on
    ///      the first message rather than quietly on a forged one.
    function testFuzz_theUnboundContractsAcceptNobody(address anyone) public {
        assertFalse(new LzReceiver().isAuthorizedGateway(anyone));
        assertFalse(new LzTransmitter().isAuthorizedGateway(anyone));
    }
}
