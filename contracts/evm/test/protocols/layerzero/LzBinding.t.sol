// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";

import {LzHubTransceiver} from "src/protocols/layerzero/LzHubTransceiver.sol";
import {LzReceiver, ILzReceiverInit} from "src/protocols/layerzero/LzReceiver.sol";
import {LzSpokeTransceiver} from "src/protocols/layerzero/LzSpokeTransceiver.sol";
import {Origin} from
    "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";
import {
    ProviderHubSendSpec,
    IHubSendHarness,
    ProviderReceiveSpec
} from "test/protocols/ProviderBindingSpec.t.sol";

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
contract LzSendTest is ProviderHubSendSpec {
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
}

/// @notice Confirms the R3.3 exception is real: LayerZero rejects a wrong sender inside the
///         vendored OApp SDK, before `_lzReceive` — and therefore this protocol's own code —
///         ever runs. `ProviderReceiveSpec` fixes the four properties this must satisfy;
///         where each is enforced is LayerZero-specific and documented on the hooks below.
contract LzReceiveTest is ProviderReceiveSpec {
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
        vm.expectRevert(LzSpokeTransceiver.ZeroHomeEid.selector);
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
        vm.expectRevert(LzSpokeTransceiver.InvalidHomeTransceiverLength.selector);
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
