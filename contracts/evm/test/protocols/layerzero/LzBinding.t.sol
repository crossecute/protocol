// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Proxy, IProxy} from "src/conduit/Proxy.sol";

import {Call} from "src/messaging/Call.sol";
import {LzReceiver, ILzReceiverInit} from "src/protocols/layerzero/LzReceiver.sol";
import {LzHomePeer} from "src/protocols/layerzero/LzHomePeer.sol";
import {LzMessage, UlnConfig} from "src/protocols/layerzero/LzMessage.sol";
import {LzWriteOncePeer} from "src/protocols/layerzero/LzWriteOncePeer.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";
import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {Payload} from "src/messaging/Payload.sol";
import {
    ProviderIdTableSpec,
    ProviderWideSenderSpec,
    ProviderSignedLockSpec,
    ProviderPayloadPricedSpec,
    ProviderRefundSpec,
    ProviderTransmitterSpec,
    ProviderTransmitterSendSpec,
    ProviderDefaultGasSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {toBytes32} from "test/Harness.sol";
import {LzTransmitter} from "src/protocols/layerzero/LzTransmitter.sol";
import {LzFixture} from "test/protocols/layerzero/LzFixture.sol";

/// @notice LayerZero delivers to the eid's peer, never to the recipient's address, so the
///         destination check is the eid alone.
/// @dev Any ULN config: the mock endpoint keeps one as the struct a library keeps.
function someUlnConfig() pure returns (bytes memory) {
    address[] memory required = new address[](1);
    required[0] = address(0xC0FFEE);
    return abi.encode(UlnConfig(0, 1, LzMessage.NIL_DVN_COUNT, 0, required, new address[](0)));
}

contract LzTransceiverSendTest is
    ProviderIdTableSpec,
    ProviderPayloadPricedSpec,
    ProviderRefundSpec,
    ProviderDefaultGasSpec,
    LzFixture
{
    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(endpoint.sentLength(), 1);
        assertEq(endpoint.sent(0).dstEid, BASE_EID);
    }

    function _supportedAttribute() internal pure override returns (bytes memory) {
        return abi.encodePacked(LzMessage.OPTIONS_ATTRIBUTE, hex"0003");
    }

    function _lastPaid() internal view override returns (uint256) {
        return endpoint.sent(endpoint.sentLength() - 1).value;
    }

    function _lastSentBody() internal view override returns (bytes memory) {
        return endpoint.sent(endpoint.sentLength() - 1).message;
    }

    function _setProviderFeePerByte(uint256 perByte) internal override {
        endpoint.setFeePerByte(perByte);
    }

    function _lastRefundAddress() internal view override returns (address) {
        return endpoint.sent(endpoint.sentLength() - 1).refundAddress;
    }

    /// @dev OApp refuses an eid with no peer before the binding's table is consulted.
    function _unmappedOriginRevert(uint256 providerId) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(IOAppCore.NoPeer.selector, uint32(providerId));
    }
}

/// @notice A receiver's peer is written once by its initializer. No owner is ever
///         initialized, so OApp's `onlyOwner` setters are uncallable and the peer is final.
abstract contract LzFixedPeerCheck is Test {
    function _assertPeerIsFixed(address oapp, uint32 eid, address peer) internal {
        assertEq(IOAppCore(oapp).peers(eid), bytes32(uint256(uint160(peer))));
        assertEq(OwnableUpgradeable(oapp).owner(), address(0));

        // Not address(0): it is `owner()`, but no transaction can come from it.
        address[3] memory callers = [peer, address(this), address(0x5165)];
        for (uint256 i; i < callers.length; ++i) {
            bytes memory denied =
                abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, callers[i]);
            vm.prank(callers[i]);
            vm.expectRevert(denied);
            IOAppCore(oapp).setPeer(eid, bytes32(uint256(0xBAD)));
            vm.prank(callers[i]);
            vm.expectRevert(denied);
            IOAppCore(oapp).setDelegate(callers[i]);
        }
    }
}

/// @notice Where an owner exists (transceiver, transmitter), `setPeer` is write-once per eid.
abstract contract LzWriteOncePeerCheck is Test {
    function _assertPeerIsWriteOnce(address oapp, address owner, uint32 eid) internal {
        bytes32 peer = bytes32(uint256(0xA11CE));

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        IOAppCore(oapp).setPeer(eid, peer);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LzWriteOncePeer.ZeroPeer.selector, eid));
        IOAppCore(oapp).setPeer(eid, bytes32(0));

        vm.startPrank(owner);
        IOAppCore(oapp).setPeer(eid, peer);
        IOAppCore(oapp).setPeer(eid, peer);
        assertEq(IOAppCore(oapp).peers(eid), peer);

        vm.expectRevert(abi.encodeWithSelector(LzWriteOncePeer.PeerAlreadySet.selector, eid));
        IOAppCore(oapp).setPeer(eid, bytes32(uint256(0xB0B)));
        vm.stopPrank();
    }
}

/// @notice LayerZero rejects a wrong sender inside the vendored OApp SDK, before `_lzReceive`
///         and therefore this protocol's own code ever runs (the R3.3 exception).
contract LzReceiveTest is ProviderWideSenderSpec, ProviderSignedLockSpec, LzFixedPeerCheck, LzFixture {
    function test_thePeerHasNoSetter() public {
        _assertPeerIsFixed(receiver, BASE_EID, SOURCE_TRANSMITTER);
    }

    /// @dev #51: the receiver has no owner, so its endpoint config changes only through its own
    ///      payload, from its transmitter.
    function test_onlyAPayloadReconfiguresTheReceiver() public {
        address lib = endpoint.RECEIVE_LIBRARY();
        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam(BASE_EID, LzMessage.ULN_CONFIG_TYPE, someUlnConfig());

        vm.expectRevert(MockLzEndpoint.Unauthorized.selector);
        endpoint.setConfig(receiver, lib, params);

        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(endpoint), 0, abi.encodeCall(MockLzEndpoint.setConfig, (receiver, lib, params)));
        _deliver(receiver, BASE_EID, toBytes32(SOURCE_TRANSMITTER), Payload.encodeCalls(calls));
        assertEq(endpoint.configOf(receiver, lib, BASE_EID, LzMessage.ULN_CONFIG_TYPE), someUlnConfig());
    }

    /// @dev OApp's own peer check, which compares all 32 bytes, refuses it first.
    function _wideSenderRevert(bytes32 wide) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, BASE_EID, wide);
    }
}

/// @notice A zero eid must not silently leave a receiver with no peer.
contract LzInitValidationTest is Test {
    address ENDPOINT = address(new MockLzEndpoint());

    function test_receiverRejectsZeroHomeEid() public {
        address impl = address(new LzReceiver(ENDPOINT, address(0), address(0)));
        address proxy = address(new Proxy());
        vm.expectRevert(LzHomePeer.ZeroHomeEid.selector);
        IProxy(proxy)
            .upgradeInitializeAndLock(
                impl, abi.encodeCall(ILzReceiverInit.initialize, (address(0xABCD), new Call[](0), 0, address(0)))
            );
    }
}

contract LzTransmitterInboundTest is ProviderTransmitterSpec, LzWriteOncePeerCheck, LzFixture {
    function test_thePeerIsWriteOnce() public {
        _assertPeerIsWriteOnce(_transmitter(), address(this), BASE_EID);
    }
}

contract LzTransmitterSendTest is ProviderTransmitterSendSpec, LzFixture {
    function _prepareConduit(address conduit_, address owner) internal override {
        _peerWithItsReceiver(conduit_, owner);
    }

    function _stack(address a, address b) private pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    /// @dev #94: the owner sets the conduit's DVN stack in one call, which keeps the conduit its
    ///      own delegate and pins the default send library.
    function test_theOwnerSetsItsDvnStack() public {
        address[] memory required = _stack(address(0xD1), address(0xD2));
        address[] memory optional = new address[](1);
        optional[0] = address(0xD3);
        vm.expectEmit(true, false, false, true, conduit);
        emit LzTransmitter.DvnsSet(BASE_EID, required, optional, 1);
        vm.prank(CONDUIT_OWNER);
        LzTransmitter(conduit).setDvn(BASE_EID, required, optional, 1);

        assertEq(endpoint.sendLibraryOf(conduit, BASE_EID), endpoint.SEND_LIBRARY());
        assertEq(
            endpoint.configOf(conduit, endpoint.SEND_LIBRARY(), BASE_EID, LzMessage.ULN_CONFIG_TYPE),
            abi.encode(UlnConfig(0, 2, 1, 1, required, optional))
        );
        assertEq(endpoint.delegateOf(conduit), conduit, "the conduit stays its own delegate");
    }

    function test_theOwnerReplacesItsStackAndEmptyMeansNone() public {
        vm.startPrank(CONDUIT_OWNER);
        LzTransmitter(conduit).setDvn(BASE_EID, _stack(address(0xD1), address(0xD2)), new address[](0), 0);
        address[] memory one = new address[](1);
        one[0] = address(0xD4);
        LzTransmitter(conduit).setDvn(BASE_EID, one, new address[](0), 0);
        vm.stopPrank();
        assertEq(
            endpoint.configOf(conduit, endpoint.SEND_LIBRARY(), BASE_EID, LzMessage.ULN_CONFIG_TYPE),
            abi.encode(UlnConfig(0, 1, LzMessage.NIL_DVN_COUNT, 0, one, new address[](0)))
        );
    }

    function test_onlyTheOwnerSetsTheStack() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        LzTransmitter(conduit).setDvn(BASE_EID, _stack(address(0xD1), address(0xD2)), new address[](0), 0);
    }

    function test_aStackTooLongToCountIsRefused() public {
        vm.prank(CONDUIT_OWNER);
        vm.expectRevert(LzMessage.TooManyDvns.selector);
        LzTransmitter(conduit).setDvn(BASE_EID, new address[](255), new address[](0), 0);
    }

    /// @dev #51: the owner reconfigures the conduit's sends, such as toward zkSync whose default
    ///      DVN refuses every message, by naming itself delegate through OApp's `setDelegate`.
    function test_theOwnerCanReconfigureTheConduit() public {
        address lib = endpoint.SEND_LIBRARY();
        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam(BASE_EID, LzMessage.ULN_CONFIG_TYPE, someUlnConfig());

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        LzTransmitter(conduit).setDelegate(address(0xBAD));

        vm.startPrank(CONDUIT_OWNER);
        LzTransmitter(conduit).setDelegate(CONDUIT_OWNER);
        endpoint.setConfig(conduit, lib, params);
        vm.stopPrank();
        assertEq(endpoint.configOf(conduit, lib, BASE_EID, LzMessage.ULN_CONFIG_TYPE), someUlnConfig());
    }
}
