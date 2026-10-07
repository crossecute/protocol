// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CrossProxy, ICrossProxy} from "src/account/CrossProxy.sol";

import {Call} from "src/messaging/Call.sol";
import {LzReceiver, ILzReceiverInit} from "src/protocols/layerzero/LzReceiver.sol";
import {LzHomePeer} from "src/protocols/layerzero/LzHomePeer.sol";
import {LzMessage} from "src/protocols/layerzero/LzMessage.sol";
import {LzWriteOncePeer} from "src/protocols/layerzero/LzWriteOncePeer.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";
import {
    ProviderIdTableSpec,
    ProviderWideSenderSpec,
    ProviderPayloadPricedSpec,
    ProviderRefundSpec,
    ProviderTransmitterSpec,
    ProviderTransmitterSendSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {toBytes32} from "test/protocols/ProviderFixture.sol";
import {LzTransmitter} from "src/protocols/layerzero/LzTransmitter.sol";
import {LzFixture} from "test/protocols/layerzero/LzFixture.sol";

/// @notice LayerZero delivers to the eid's peer, never to the recipient's address, so the
///         destination check is the eid alone.
contract LzTransceiverSendTest is ProviderIdTableSpec, ProviderPayloadPricedSpec, ProviderRefundSpec, LzFixture {
    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(endpoint.sentLength(), 1);
        (uint32 dstEid,,,,,) = endpoint.sent(0);
        assertEq(dstEid, BASE_EID);
    }

    function _supportedAttribute() internal pure override returns (bytes memory) {
        return abi.encodePacked(LzMessage.OPTIONS_ATTRIBUTE, hex"0003");
    }

    function _lastPaid() internal view override returns (uint256 value) {
        (,,,, value,) = endpoint.sent(endpoint.sentLength() - 1);
    }

    function _lastSentBody() internal view override returns (bytes memory message) {
        (,, message,,,) = endpoint.sent(endpoint.sentLength() - 1);
    }

    function _setProviderFeePerByte(uint256 perByte) internal override {
        endpoint.setFeePerByte(perByte);
    }

    function _lastRefundAddress() internal view override returns (address refundAddress) {
        (,,,,, refundAddress) = endpoint.sent(endpoint.sentLength() - 1);
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
contract LzReceiveTest is ProviderWideSenderSpec, LzFixedPeerCheck, LzFixture {
    function test_thePeerHasNoSetter() public {
        _assertPeerIsFixed(receiver, BASE_EID, SOURCE_TRANSMITTER);
    }

    /// @dev OApp's own `NoPeer`.
    function _deliverFromUnconfiguredOrigin() internal override {
        _deliver(receiver, BASE_EID + 1, toBytes32(SOURCE_TRANSMITTER), _emptyPayload());
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
        address impl = address(new LzReceiver(ENDPOINT));
        address proxy = address(new CrossProxy());
        vm.expectRevert(LzHomePeer.ZeroHomeEid.selector);
        ICrossProxy(proxy)
            .upgradeInitializeAndLock(
                impl, abi.encodeCall(ILzReceiverInit.initialize, (address(0xABCD), new Call[](0), 0))
            );
    }
}

contract LzTransmitterInboundTest is ProviderTransmitterSpec, LzWriteOncePeerCheck, LzFixture {
    function test_thePeerIsWriteOnce() public {
        _assertPeerIsWriteOnce(_transmitter(), address(this), BASE_EID);
    }
}

contract LzTransmitterSendTest is ProviderTransmitterSendSpec, LzFixture {
    /// @dev LayerZero delivers only from a set peer: here the receiver, at the account's address.
    function _prepareAccount(address account_) internal override {
        vm.prank(ACCOUNT_OWNER);
        LzTransmitter(payable(account_)).setPeer(BASE_EID, toBytes32(account_));
    }
}
