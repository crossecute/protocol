// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";

import {LzHubTransceiver} from "src/protocols/layerzero/LzHubTransceiver.sol";
import {LzReceiver, ILzReceiverInit} from "src/protocols/layerzero/LzReceiver.sol";
import {LzSpokeTransceiver, LzSpokeBase} from "src/protocols/layerzero/LzSpokeTransceiver.sol";
import {LzZkSyncSpokeTransceiver} from
    "src/protocols/layerzero/LzDivergentSpokeTransceiver.sol";
import {Origin} from
    "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";
import {
    ProviderIdTableSpec,
    IHubSendHarness,
    ProviderWideSenderSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";

/// @notice Exposes `_sendMessage`/`_quoteMessage` directly for isolated eid-resolution
///         testing (bootstrap/ownership machinery is covered by `test/Transport.t.sol`).
contract LzHubHarness is LzHubTransceiver {
    constructor(address endpoint) LzHubTransceiver(endpoint) {}

    function sendMessagePublic(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value
    ) external payable returns (bytes32) {
        return _sendMessage(recipient, payload, attributes, value);
    }

    function quoteMessagePublic(bytes memory recipient, bytes memory payload)
        external
        view
        returns (uint256)
    {
        return _quoteMessage(recipient, payload, new bytes[](0));
    }
}

/// @notice The eid-resolution/quote/unconfigured-destination properties are
///         `ProviderHubSendSpec`'s; this contract only supplies LayerZero's own mock and, in
///         `test_sendForwardsThePayloadAndValueUnchanged`, the one property the spec doesn't
///         cover (the message bytes and value reach the endpoint unchanged).
contract LzSendTest is ProviderIdTableSpec {
    MockLzEndpoint endpoint;
    LzHubHarness hub;
    address msig = address(0x5165);
    bytes32 baseKey;
    uint32 constant BASE_EID = 30184;

    function setUp() public {
        endpoint = new MockLzEndpoint();
        hub = LzHubHarness(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new LzHubHarness(address(endpoint))),
                        abi.encodeCall(
                            LzHubTransceiver.initialize,
                            (msig, address(0), new address[](0), address(0xBEEF))
                        )
                    )
                )
            )
        );
        harness = IHubSendHarness(address(hub));

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
        hub.sendMessagePublic{value: 0.01 ether}(
            _configuredRecipient(), payload, new bytes[](0), 0.01 ether
        );

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
        hub.sendMessagePublic{value: 0.02 ether}(
            _configuredRecipient(), "x", new bytes[](0), 0.01 ether
        );

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
}

/// @notice Confirms the R3.3 exception is real: LayerZero rejects a wrong sender inside the
///         vendored OApp SDK, before `_lzReceive` — and therefore this protocol's own code —
///         ever runs. `ProviderReceiveSpec` fixes the four properties this must satisfy;
///         where each is enforced is LayerZero-specific and documented on the hooks below.
contract LzReceiveTest is ProviderWideSenderSpec {
    MockLzEndpoint endpoint;
    LzReceiver receiver;
    address sourceTransmitter = address(0xABCD);
    uint32 constant HOME_EID = 30101;

    function setUp() public {
        endpoint = new MockLzEndpoint();
        receiver = LzReceiver(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new LzReceiver(address(endpoint))),
                        abi.encodeCall(
                            ILzReceiverInit.initialize,
                            (sourceTransmitter, new Call[](0), HOME_EID)
                        )
                    )
                )
            )
        );
    }

    function _origin(address sender, uint32 eid) internal pure returns (Origin memory) {
        return Origin({srcEid: eid, sender: bytes32(uint256(uint160(sender))), nonce: 1});
    }

    function _receiverUnderTest() internal view override returns (address) {
        return address(receiver);
    }

    function _gateway() internal view override returns (address) {
        return address(endpoint);
    }

    function _deliverFromConfiguredSource() internal override {
        bytes memory payload = Payload.encodeCalls(new Call[](0));
        vm.prank(address(endpoint));
        receiver.lzReceive(
            _origin(sourceTransmitter, HOME_EID), bytes32(0), payload, address(0), ""
        );
    }

    /// @dev OApp's own `OnlyPeer`, ahead of `_lzReceive`.
    function _deliverFromImpersonator() internal override {
        vm.prank(address(endpoint));
        receiver.lzReceive(_origin(address(0xBAD), HOME_EID), bytes32(0), "", address(0), "");
    }

    /// @dev OApp's own `NoPeer`.
    function _deliverFromUnconfiguredOrigin() internal override {
        vm.prank(address(endpoint));
        receiver.lzReceive(
            _origin(sourceTransmitter, HOME_EID + 1), bytes32(0), "", address(0), ""
        );
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

/// @notice The Copilot-flagged gap: a zero eid or a mis-sized `homeTransceiver_` must not
///         silently misconfigure the LayerZero peer.
contract LzInitValidationTest is Test {
    address ENDPOINT = address(new MockLzEndpoint());

    function test_receiverRejectsZeroHomeEid() public {
        address impl = address(new LzReceiver(ENDPOINT));
        vm.expectRevert(LzReceiver.ZeroHomeEid.selector);
        new ERC1967Proxy(
            impl,
            abi.encodeCall(ILzReceiverInit.initialize, (address(0xABCD), new Call[](0), 0))
        );
    }

    function test_spokeRejectsZeroHomeEid() public {
        address impl = address(new LzSpokeTransceiver(ENDPOINT));
        vm.expectRevert(LzSpokeBase.ZeroHomeEid.selector);
        new ERC1967Proxy(
            impl,
            abi.encodeCall(
                LzSpokeTransceiver.initialize,
                (
                    new address[](0),
                    address(0xBEEF),
                    ChainKey.forEvm(1),
                    Erc7930.encodeEvmChain(1),
                    abi.encodePacked(address(0xC0DE)),
                    uint32(0)
                )
            )
        );
    }

    function test_spokeRejectsAMissizedHomeTransceiver() public {
        address impl = address(new LzSpokeTransceiver(ENDPOINT));
        vm.expectRevert(LzSpokeBase.InvalidHomeTransceiverLength.selector);
        new ERC1967Proxy(
            impl,
            abi.encodeCall(
                LzSpokeTransceiver.initialize,
                (
                    new address[](0),
                    address(0xBEEF),
                    ChainKey.forEvm(1),
                    Erc7930.encodeEvmChain(1),
                    abi.encodePacked(address(0xC0DE), uint8(1)), // 21 bytes, not 20
                    uint32(1)
                )
            )
        );
    }
}

/// @notice Exposes `_sendMessage` directly, the same shape as `LzHubHarness`, to test the
///         one send a diverging spoke ever makes: its receiver report.
contract LzZkSyncSpokeHarness is LzZkSyncSpokeTransceiver {
    constructor(address endpoint) LzZkSyncSpokeTransceiver(endpoint) {}

    function sendMessagePublic(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value
    ) external payable returns (bytes32) {
        return _sendMessage(recipient, payload, attributes, value);
    }
}

/// @notice The other Copilot-flagged gap on PR #6: `_reportReceiver` runs nested inside the
///         `lzReceive` delivery callback, where `msg.value` is 0, and is documented
///         (`SpokeTransceiverBase._reportReceiver`) to spend from the spoke's own balance.
///         Without `LzSpokeBase._payNative`, this reverted `NotEnoughNative` on
///         every zkSync/Tron account bootstrap.
contract LzDivergentSpokePayNativeTest is Test {
    MockLzEndpoint endpoint;
    LzZkSyncSpokeHarness spoke;
    bytes32 constant HASH = keccak256("zksolc-artifact");
    uint32 constant HOME_EID = 30101;

    function setUp() public {
        endpoint = new MockLzEndpoint();
        spoke = LzZkSyncSpokeHarness(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new LzZkSyncSpokeHarness(address(endpoint))),
                        abi.encodeCall(
                            LzZkSyncSpokeTransceiver.initialize,
                            (
                                new address[](0),
                                address(0xBEEF),
                                ChainKey.forEvm(1),
                                Erc7930.encodeEvmChain(1),
                                abi.encodePacked(address(0xC0DE)),
                                HASH,
                                HOME_EID
                            )
                        )
                    )
                )
            )
        );
    }

    function test_reportSpendsFromTheSpokesOwnBalance() public {
        endpoint.setFee(0.01 ether);
        vm.deal(address(spoke), 1 ether);

        // No {value: ...}: reproduces msg.value == 0 inside the delivery callback.
        spoke.sendMessagePublic(Erc7930.encodeEvmChain(1), "report", new bytes[](0), 0.01 ether);

        (,,,, uint256 value,) = endpoint.sent(0);
        assertEq(value, 0.01 ether);
    }
}
