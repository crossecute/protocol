// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LzOftReceiver, ILzOftReceiverInit} from "src/protocols/layerzero/LzOftReceiver.sol";
import {LzOftMessage} from "src/protocols/layerzero/LzOftMessage.sol";
import {Executor} from "src/messaging/Executor.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {deployConduit} from "test/DeployCrossProxy.sol";
import {MockOft} from "test/protocols/layerzero/MockOft.sol";
import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";

contract Target {
    uint256 public hits;
    bool public open = true;

    function setOpen(bool o) external {
        open = o;
    }

    function hit() external {
        require(open, "closed");
        ++hits;
    }
}

/// @dev What is specific to an OFT compose. The checks every receiver shares run in
///      `LzOftBinding.t.sol` through `ProviderWideSenderSpec`.
contract LzOftReceiverTest is Test {
    MockLzEndpoint endpoint;
    MockOft localOft;
    LzOftReceiver receiver;
    Target target;

    uint32 constant HOME_EID = 30184;
    address constant HOME_OFT = address(0x40F7);
    address constant TRANSMITTER = address(0x7A11);
    address constant EXECUTOR = address(0xE0EC);
    bytes32 constant GUID = keccak256("guid");

    function setUp() public {
        endpoint = new MockLzEndpoint();
        localOft = new MockOft(address(endpoint));
        localOft.setPeer(HOME_EID, HOME_OFT);
        target = new Target();
        receiver = LzOftReceiver(
            payable(deployConduit(
                    address(new LzOftReceiver()),
                    abi.encodeCall(
                        ILzOftReceiverInit.initialize,
                        (TRANSMITTER, HOME_EID, HOME_OFT, address(localOft), new Call[](0))
                    )
                ))
        );
    }

    function _payload() internal view returns (bytes memory) {
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(target), 0, abi.encodeCall(Target.hit, ()));
        return Payload.encodeCalls(calls);
    }

    /// @dev The OFT credits and queues; the executor then calls the endpoint.
    function _deliver(MockOft oft, uint32 srcEid, address from) internal returns (bytes memory m) {
        m = oft.receivePacket(srcEid, GUID, address(receiver), from, _payload());
        vm.prank(EXECUTOR);
        endpoint.lzCompose(address(oft), address(receiver), GUID, 0, m, "");
    }

    /// @dev Any contract can queue a compose for any `to`; the endpoint reports it as `_from`.
    function test_aComposeQueuedByAnotherContractIsRefused() public {
        MockOft fake = new MockOft(address(endpoint));
        fake.setPeer(HOME_EID, HOME_OFT);
        bytes memory m = fake.receivePacket(HOME_EID, GUID, address(receiver), TRANSMITTER, _payload());
        vm.expectRevert(abi.encodeWithSelector(LzOftReceiver.NotTheOft.selector, address(fake)));
        endpoint.lzCompose(address(fake), address(receiver), GUID, 0, m, "");
    }

    function test_aRePeeredLocalOftIsRefused() public {
        bytes memory m = localOft.receivePacket(HOME_EID, GUID, address(receiver), TRANSMITTER, _payload());
        localOft.setPeer(HOME_EID, address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                LzOftMessage.PeerChanged.selector,
                HOME_EID,
                bytes32(uint256(uint160(HOME_OFT))),
                bytes32(uint256(uint160(address(0xBAD))))
            )
        );
        endpoint.lzCompose(address(localOft), address(receiver), GUID, 0, m, "");
    }

    /// @dev C29: the endpoint marks a compose before calling, so a success is final.
    function test_aDeliveredComposeCannotRunAgain() public {
        bytes memory m = _deliver(localOft, HOME_EID, TRANSMITTER);
        vm.expectPartialRevert(MockLzEndpoint.ComposeNotFound.selector);
        endpoint.lzCompose(address(localOft), address(receiver), GUID, 0, m, "");
        assertEq(target.hits(), 1);
    }

    /// @dev A reverting payload rolls the mark back, so anyone retries it once it can succeed.
    function test_aFailedComposeIsRetried() public {
        target.setOpen(false);
        bytes memory m = localOft.receivePacket(HOME_EID, GUID, address(receiver), TRANSMITTER, _payload());
        vm.expectPartialRevert(Executor.CallFailed.selector);
        endpoint.lzCompose(address(localOft), address(receiver), GUID, 0, m, "");

        target.setOpen(true);
        endpoint.lzCompose(address(localOft), address(receiver), GUID, 0, m, "");
        assertEq(target.hits(), 1);
    }

    function test_thePlainInitializerIsRefused() public {
        LzOftReceiver logic = new LzOftReceiver();
        vm.expectRevert(LzOftReceiver.UseLzOftInitializer.selector);
        logic.initialize(TRANSMITTER, bytes32(uint256(HOME_EID)), new Call[](0));
    }

    function test_theStateIsSet() public view {
        assertEq(receiver.sourceTransmitter(), TRANSMITTER);
        assertEq(receiver.homeOrigin(), bytes32(uint256(HOME_EID)));
        assertEq(receiver.homeOft(), HOME_OFT);
        assertEq(receiver.localOft(), address(localOft));
    }
}
