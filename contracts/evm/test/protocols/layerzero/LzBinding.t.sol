// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";

import {LzReceiver, ILzReceiverInit} from "src/protocols/layerzero/LzReceiver.sol";
import {LzHomePeer} from "src/protocols/layerzero/LzHomePeer.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";
import {
    ProviderIdTableSpec,
    ISendHarness,
    ProviderWideSenderSpec,
    ProviderPayloadPricedSpec,
    ProviderRefundSpec,
    ProviderTransmitterSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {LzWriteOncePeer} from "src/protocols/layerzero/LzWriteOncePeer.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {LzTransmitter} from "src/protocols/layerzero/LzTransmitter.sol";
import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";

/// @notice What the LayerZero send suite drives, on the hub and on the transceiver that is hub
///         and spoke at once alike.
interface ILzSendHarness is ISendHarness {
    function setEid(bytes32 chainKey, uint32 eid) external;
    function setPeer(uint32 eid, bytes32 peer) external;
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable;
    function LZ_OPTIONS_ATTRIBUTE() external view returns (bytes4);
}

/// @notice The eid-resolution/quote/unconfigured-destination properties are
///         `ProviderSendSpec`'s; this suite only supplies LayerZero's own mock and, in
///         `test_sendForwardsThePayloadAndValueUnchanged`, the one property the spec doesn't
///         cover (the message bytes and value reach the endpoint unchanged). Run against each
///         LayerZero transceiver through `_deploy`.
abstract contract LzSendSuite is ProviderIdTableSpec, ProviderPayloadPricedSpec, ProviderRefundSpec {
    MockLzEndpoint endpoint;
    ILzSendHarness hub;
    address msig;
    bytes32 baseKey;
    uint32 constant BASE_EID = 30184;

    /// @notice Deploy the transceiver under test against `endpoint`, returning it and its owner.
    function _deploy() internal virtual returns (address transceiver, address owner);

    function setUp() public {
        endpoint = new MockLzEndpoint();
        (address t, address owner) = _deploy();
        hub = ILzSendHarness(t);
        msig = owner;
        harness = ISendHarness(address(hub));

        vm.startPrank(msig);
        baseKey = ChainKey.forEvm(8453);
        hub.setEid(baseKey, BASE_EID);
        hub.setPeer(BASE_EID, bytes32(uint256(uint160(address(0xB45E)))));
        vm.stopPrank();
    }

    function _configuredRecipient() internal pure override returns (bytes memory) {
        return Erc7930.encodeEvm(8453, address(0xC0DE));
    }

    function _unconfiguredRecipient() internal pure override returns (bytes memory) {
        return Erc7930.encodeEvm(1, address(0xC0DE));
    }

    function _configuredProviderId() internal pure override returns (uint256) {
        return BASE_EID;
    }

    function _setProviderFee(uint256 fee) internal override {
        endpoint.setFee(fee);
    }

    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(endpoint.sentLength(), 1);
        (uint32 dstEid,,,,,) = endpoint.sent(0);
        assertEq(dstEid, BASE_EID);
    }

    function test_sendForwardsThePayloadAndValueUnchanged() public {
        endpoint.setFee(0.01 ether);
        bytes memory payload = "payload";

        vm.deal(address(this), 1 ether);
        hub.sendMessagePublic{value: 0.01 ether}(_configuredRecipient(), payload, new bytes[](0), 0.01 ether);

        (,, bytes memory sentPayload,, uint256 value,) = endpoint.sent(0);
        assertEq(sentPayload, payload);
        assertEq(value, 0.01 ether);
    }

    /// @notice The bootstrap-fee case Copilot flagged on PR #6: `_bootstrapSendValue`
    ///         returns `msg.value - fee`, so `value < msg.value` here on purpose, and the
    ///         vendored `_payNative` default (which requires `msg.value == value` exactly)
    ///         would revert `NotEnoughNative` on every bootstrap once a fee is configured.
    function test_sendSpendsExactlyValueEvenWhenLessThanMsgValue() public {
        endpoint.setFee(0.01 ether);
        vm.deal(address(this), 1 ether);
        hub.sendMessagePublic{value: 0.02 ether}(_configuredRecipient(), "x", new bytes[](0), 0.01 ether);

        (,,,, uint256 value,) = endpoint.sent(0);
        assertEq(value, 0.01 ether, "spends value, not msg.value");
    }

    /// @notice The nested-send case: msg.value is 0 (as it is inside a delivery callback,
    ///         where a diverging spoke's receiver report is sent from its own balance), and
    ///         `value` is still paid, drawn from the contract's pre-funded balance.
    function test_sendSpendsFromBalanceWhenMsgValueIsZero() public {
        endpoint.setFee(0.01 ether);
        vm.deal(address(hub), 1 ether);
        hub.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0.01 ether);

        (,,,, uint256 value,) = endpoint.sent(0);
        assertEq(value, 0.01 ether);
    }

    /// @dev A malformed first attribute is reported even when an extra follows it.
    function test_malformedFirstAttributeIsReportedBeforeAnExtra() public {
        bytes[] memory attrs = new bytes[](2);
        attrs[0] = abi.encodePacked(bytes4(0xdeadbeef), hex"0003");
        attrs[1] = abi.encodePacked(hub.LZ_OPTIONS_ATTRIBUTE(), hex"0003");
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        hub.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function _lastPaid() internal view override returns (uint256 value) {
        (,,,, value,) = endpoint.sent(endpoint.sentLength() - 1);
    }

    function _setProviderFeePerByte(uint256 perByte) internal override {
        endpoint.setFeePerByte(perByte);
    }

    function _lastRefundAddress() internal view override returns (address refundAddress) {
        (,,,,, refundAddress) = endpoint.sent(endpoint.sentLength() - 1);
    }

    function _setProviderIdAsOwner(bytes32 chainKey, uint256 providerId) internal override {
        vm.prank(msig);
        hub.setEid(chainKey, uint32(providerId));
    }

    function _deliverFromUnmappedOrigin(uint256 providerId) internal override {
        vm.prank(address(endpoint));
        hub.lzReceive(
            Origin({srcEid: uint32(providerId), sender: bytes32(uint256(0xC0DE)), nonce: 1}),
            bytes32(0),
            "",
            address(0),
            ""
        );
    }

    /// @dev OApp refuses an eid with no peer before the binding's table is consulted.
    function _unmappedOriginRevert(uint256 providerId) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(IOAppCore.NoPeer.selector, uint32(providerId));
    }
}

/// @notice Confirms the R3.3 exception is real: LayerZero rejects a wrong sender inside the
///         vendored OApp SDK, before `_lzReceive` — and therefore this protocol's own code —
///         ever runs. `ProviderReceiveSpec` fixes the four properties this must satisfy;
///         where each is enforced is LayerZero-specific and documented on the hooks below.
/// @notice A receiver's or spoke's peer is written once by its initializer. No owner is ever
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

/// @notice Where an owner exists (hub, transmitter), `setPeer` is write-once per eid.
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

contract LzReceiveTest is ProviderWideSenderSpec, LzFixedPeerCheck {
    MockLzEndpoint endpoint;
    LzReceiver receiver;
    address sourceTransmitter = address(0xABCD);
    uint32 constant HOME_EID = 30101;

    function setUp() public {
        endpoint = new MockLzEndpoint();
        receiver = LzReceiver(payable(_deployReceiver(new Call[](0))));
    }

    /// @dev Initialized in a second call, as `CrossProxy` is: a proxy initialized from its own
    ///      constructor has no code yet, so a payload calling back into it would see none.
    function _deployReceiver(Call[] memory calls) internal override returns (address proxy) {
        proxy = address(new ERC1967Proxy(address(new LzReceiver(address(endpoint))), ""));
        ILzReceiverInit(proxy).initialize(sourceTransmitter, calls, HOME_EID);
    }

    function _origin(address sender, uint32 eid) internal pure returns (Origin memory) {
        return Origin({srcEid: eid, sender: bytes32(uint256(uint160(sender))), nonce: 1});
    }

    function _receiverUnderTest() internal view override returns (address) {
        return address(receiver);
    }

    function test_thePeerHasNoSetter() public {
        _assertPeerIsFixed(address(receiver), HOME_EID, sourceTransmitter);
    }

    function _gateway() internal view override returns (address) {
        return address(endpoint);
    }

    function _deliverFromConfiguredSource() internal override {
        bytes memory payload = Payload.encodeCalls(new Call[](0));
        vm.prank(address(endpoint));
        receiver.lzReceive(_origin(sourceTransmitter, HOME_EID), bytes32(0), payload, address(0), "");
    }

    /// @dev OApp's own `OnlyPeer`, ahead of `_lzReceive`.
    function _deliverFromImpersonator() internal override {
        vm.prank(address(endpoint));
        receiver.lzReceive(_origin(address(0xBAD), HOME_EID), bytes32(0), "", address(0), "");
    }

    /// @dev OApp's own `NoPeer`.
    function _deliverFromUnconfiguredOrigin() internal override {
        vm.prank(address(endpoint));
        receiver.lzReceive(_origin(sourceTransmitter, HOME_EID + 1), bytes32(0), "", address(0), "");
    }

    /// @dev OApp's own `OnlyEndpoint`: no `vm.prank`, so the caller is this test contract.
    function _deliverFromWrongCaller() internal override {
        receiver.lzReceive(_origin(sourceTransmitter, HOME_EID), bytes32(0), "", address(0), "");
    }

    function _deliverFromWideSender(bytes32 wide) internal override {
        vm.prank(address(endpoint));
        receiver.lzReceive(Origin({srcEid: HOME_EID, sender: wide, nonce: 1}), bytes32(0), "", address(0), "");
    }

    /// @dev OApp's own peer check, which compares all 32 bytes, refuses it first.
    function _wideSenderRevert(bytes32 wide) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, HOME_EID, wide);
    }
}

/// @notice A zero eid must not silently leave a receiver with no peer.
contract LzInitValidationTest is Test {
    address ENDPOINT = address(new MockLzEndpoint());

    function test_receiverRejectsZeroHomeEid() public {
        address impl = address(new LzReceiver(ENDPOINT));
        vm.expectRevert(LzHomePeer.ZeroHomeEid.selector);
        new ERC1967Proxy(impl, abi.encodeCall(ILzReceiverInit.initialize, (address(0xABCD), new Call[](0), 0)));
    }
}

contract LzTransmitterInboundTest is ProviderTransmitterSpec, LzWriteOncePeerCheck {
    MockLzEndpoint endpoint = new MockLzEndpoint();

    function _transmitter() internal override returns (address) {
        return address(
            new ERC1967Proxy(
                address(new LzTransmitter(address(endpoint))),
                abi.encodeCall(OwnableTransmitter.initialize, (address(this), address(0xB0B), bytes32(0)))
            )
        );
    }

    function _deliveringGateway() internal view override returns (address) {
        return address(endpoint);
    }

    function _deliveryCall() internal pure override returns (bytes memory) {
        return abi.encodeCall(
            ILayerZeroReceiver.lzReceive,
            (Origin({srcEid: 30101, sender: bytes32(uint256(0xABCD)), nonce: 1}), bytes32(0), "", address(0), "")
        );
    }

    function test_thePeerIsWriteOnce() public {
        _assertPeerIsWriteOnce(_transmitter(), address(this), 30184);
    }
}

