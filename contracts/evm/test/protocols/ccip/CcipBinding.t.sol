// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";

import {CcipHubTransceiver} from "src/protocols/ccip/CcipHubTransceiver.sol";
import {CcipSpokeTransceiver} from "src/protocols/ccip/CcipSpokeTransceiver.sol";
import {
    CcipZkSyncSpokeTransceiver,
    CcipTronSpokeTransceiver
} from "src/protocols/ccip/CcipDivergentSpokeTransceiver.sol";
import {CcipReceiver} from "src/protocols/ccip/CcipReceiver.sol";
import {IAny2EVMMessageReceiver} from "@ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@ccip/libraries/Client.sol";

import {MockCcipRouter} from "test/protocols/ccip/MockCcipRouter.sol";
import {ProviderIdTableSpec, IHubSendHarness, ProviderReceiveSpec, ProviderSpokeOriginSpec, ProviderEvmRecipientSpec} from "test/protocols/ProviderBindingSpec.t.sol";

/// @notice Exposes `_sendMessage`/`_quoteMessage` directly for isolated selector-resolution
///         testing (bootstrap/ownership machinery is covered by `test/Transport.t.sol`).
contract CcipHubHarness is CcipHubTransceiver {
    constructor(address router) CcipHubTransceiver(router) {}

    function sendMessagePublic(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        external
        payable
        returns (bytes32)
    {
        return _sendMessage(recipient, payload, attributes, value);
    }

    function quoteMessagePublic(bytes memory recipient, bytes memory payload) external view returns (uint256) {
        return _quoteMessage(recipient, payload, new bytes[](0));
    }
}

/// @notice The selector-resolution/quote/unconfigured-destination properties are
///         `ProviderHubSendSpec`'s; this contract supplies the mock router and, in the two
///         extra tests, the properties the spec doesn't cover: unlike LayerZero's peer
///         table, CCIP has no provider-side destination-address concept at all, so the
///         recipient's address half (unused by LayerZero) is exactly what becomes
///         `EVM2AnyMessage.receiver` here.
contract CcipSendTest is ProviderIdTableSpec, ProviderEvmRecipientSpec {
    MockCcipRouter router;
    CcipHubHarness hub;
    address msig = address(0x5165);
    bytes32 baseKey;
    uint64 constant BASE_SELECTOR = 15_971_525_489_660_198_786;

    function setUp() public {
        router = new MockCcipRouter();
        hub = CcipHubHarness(
            payable(address(
                    new ERC1967Proxy(
                        address(new CcipHubHarness(address(router))),
                        abi.encodeCall(
                            CcipHubTransceiver.initialize, (msig, address(0), new address[](0), address(0xBEEF))
                        )
                    )
                ))
        );
        harness = IHubSendHarness(address(hub));

        vm.startPrank(msig);
        baseKey = ChainKey.forEvm(8453);
        hub.setSelector(baseKey, BASE_SELECTOR);
        vm.stopPrank();
    }

    function _configuredRecipient() internal pure override returns (bytes memory) {
        return Erc7930.encodeEvm(8453, address(0xC0DE));
    }

    function _unconfiguredRecipient() internal pure override returns (bytes memory) {
        return Erc7930.encodeEvm(1, address(0xC0DE));
    }

    function _configuredProviderId() internal pure override returns (uint256) {
        return BASE_SELECTOR;
    }

    function _setProviderFee(uint256 fee) internal override {
        router.setFee(fee);
    }

    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(router.sentLength(), 1);
        (uint64 destChainSelector,,,,,) = router.sent(0);
        assertEq(destChainSelector, BASE_SELECTOR);
    }

    function test_sendUsesTheRecipientsAddressAsTheCcipReceiver() public {
        hub.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        (, bytes memory receiver,,,,) = router.sent(0);
        assertEq(receiver, abi.encode(address(0xC0DE)));
    }

    function test_sendForwardsThePayloadAndValueUnchanged() public {
        router.setFee(0.01 ether);
        bytes memory payload = "payload";

        vm.deal(address(this), 1 ether);
        hub.sendMessagePublic{value: 0.01 ether}(_configuredRecipient(), payload, new bytes[](0), 0.01 ether);

        (,, bytes memory sentPayload,,, uint256 value) = router.sent(0);
        assertEq(sentPayload, payload);
        assertEq(value, 0.01 ether);
    }

    /// @dev A malformed first attribute is reported even when an extra follows it.
    function test_malformedFirstAttributeIsReportedBeforeAnExtra() public {
        bytes[] memory attrs = new bytes[](2);
        attrs[0] = abi.encodePacked(bytes4(0xdeadbeef), abi.encode(uint256(1), true));
        attrs[1] = abi.encodePacked(hub.CCIP_EXTRA_ARGS_ATTRIBUTE(), abi.encode(uint256(1), true));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        hub.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    /// @dev Previously a short body failed inside `abi.decode` and a long one was truncated.
    function test_extraArgsOfTheWrongLengthAreRefused() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(hub.CCIP_EXTRA_ARGS_ATTRIBUTE(), uint256(1));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        hub.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_extraArgsAttributeBecomesEVMExtraArgsV2() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(hub.CCIP_EXTRA_ARGS_ATTRIBUTE(), abi.encode(uint256(500_000), true));

        hub.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);

        (,,,, bytes memory extraArgs,) = router.sent(0);
        assertEq(
            extraArgs, Client._argsToBytes(Client.EVMExtraArgsV2({gasLimit: 500_000, allowOutOfOrderExecution: true}))
        );
    }
}

/// @notice CCIP's off-ramp asserts nothing about the source-chain sender (unlike
///         LayerZero's `lzReceive`), so `isSourceTransmitter` inside `ccipReceive` is the
///         only authentication check here -- confirmed by these tests running the check
///         ourselves rather than relying on a provider-side peer rejection.
contract CcipReceiveTest is ProviderReceiveSpec {
    MockCcipRouter router;
    CcipReceiver receiver;
    address sourceTransmitter = address(0xABCD);

    function setUp() public {
        router = new MockCcipRouter();
        receiver = CcipReceiver(
            payable(address(
                    new ERC1967Proxy(
                        address(new CcipReceiver(address(router))),
                        abi.encodeCall(CcipReceiver.initialize, (sourceTransmitter, new Call[](0)))
                    )
                ))
        );
    }

    function _message(address sender, bytes memory data) internal pure returns (Client.Any2EVMMessage memory) {
        return Client.Any2EVMMessage({
            messageId: bytes32(0),
            sourceChainSelector: 1,
            sender: abi.encode(sender),
            data: data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    function _receiverUnderTest() internal view override returns (address) {
        return address(receiver);
    }

    function _gateway() internal view override returns (address) {
        return address(router);
    }

    function _deliverFromConfiguredSource() internal override {
        bytes memory payload = Payload.encodeCalls(new Call[](0));
        vm.prank(address(router));
        receiver.ccipReceive(_message(sourceTransmitter, payload));
    }

    function _deliverFromImpersonator() internal override {
        vm.prank(address(router));
        receiver.ccipReceive(_message(address(0xBAD), ""));
    }

    /// @dev `CcipReceiver` tracks no per-origin state at all -- no eid/domain/selector
    ///      table, unlike LayerZero's peer-per-eid or Hyperlane's enrolled-router-per-
    ///      domain -- so there is no distinct "wrong chain, right-shaped message" failure
    ///      to construct here: every non-source-transmitter sender is rejected the same
    ///      way regardless of `sourceChainSelector`. Reuses the impersonator path rather
    ///      than fabricate a difference CCIP's receiver binding doesn't have.
    function _deliverFromUnconfiguredOrigin() internal override {
        vm.prank(address(router));
        receiver.ccipReceive(_message(address(0xBAD), ""));
    }

    function _deliverFromWrongCaller() internal override {
        receiver.ccipReceive(_message(sourceTransmitter, ""));
    }
}

/// @notice The Copilot-adjacent gap this binding has to get right on its own: CCIP's
///         off-ramp checks `supportsInterface` before calling `ccipReceive` at all, and a
///         wrong answer fails silently (no revert -- the message just never arrives).
contract CcipInterfaceSupportTest is Test {
    function test_receiverSupportsIAny2EVMMessageReceiverAndIERC165() public {
        CcipReceiver receiver = new CcipReceiver(address(0xBEEF));
        assertTrue(receiver.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(receiver.supportsInterface(type(IERC165).interfaceId));
        assertFalse(receiver.supportsInterface(bytes4(0xdeadbeef)));
    }

    function test_hubSupportsIAny2EVMMessageReceiverAndIERC165() public {
        CcipHubTransceiver hub = new CcipHubTransceiver(address(0xBEEF));
        assertTrue(hub.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(hub.supportsInterface(type(IERC165).interfaceId));
        assertFalse(hub.supportsInterface(bytes4(0xdeadbeef)));
    }
}

/// @notice The Copilot-flagged gap: `ccipReceive` is gated `onlyRole(GATEWAY_ROLE)`, and a
///         deployment that forgot to include `router` in `gateways` would deploy
///         successfully and then reject every inbound message. The hub/spoke initializers
///         now grant the role to their own immutable `router` directly.
contract CcipGatewayRoleGrantTest is Test {
    address router = address(0xBEEF);

    function test_hubGrantsRouterTheGatewayRoleEvenWithNoGatewaysPassed() public {
        CcipHubTransceiver hub = CcipHubTransceiver(
            address(
                new ERC1967Proxy(
                    address(new CcipHubTransceiver(router)),
                    abi.encodeCall(
                        CcipHubTransceiver.initialize, (address(this), address(0), new address[](0), address(0xBEEF))
                    )
                )
            )
        );
        assertTrue(hub.hasRole(hub.GATEWAY_ROLE(), router));
    }

    function test_spokeGrantsRouterTheGatewayRoleEvenWithNoGatewaysPassed() public {
        CcipSpokeTransceiver spoke = CcipSpokeTransceiver(
            address(
                new ERC1967Proxy(
                    address(new CcipSpokeTransceiver(router)),
                    abi.encodeCall(
                        CcipSpokeTransceiver.initialize,
                        (
                            new address[](0),
                            address(0xC0DE),
                            ChainKey.forEvm(1),
                            Erc7930.encodeEvmChain(1),
                            abi.encodePacked(address(0xD00D)),
                            uint64(1)
                        )
                    )
                )
            )
        );
        assertTrue(spoke.hasRole(spoke.GATEWAY_ROLE(), router));
    }
}

contract CcipSpokeOriginTest is ProviderSpokeOriginSpec {
    address router = address(0xBEEF);
    address hub = address(0xD00D);
    uint64 constant HOME_SELECTOR = 5009297550715157269;

    function _spokes() internal override returns (address[] memory spokes) {
        bytes memory hubBytes = abi.encodePacked(hub);
        spokes = new address[](3);
        spokes[0] = address(
            new ERC1967Proxy(
                address(new CcipSpokeTransceiver(router)),
                abi.encodeCall(
                    CcipSpokeTransceiver.initialize,
                    (new address[](0), address(0xC0DE), ChainKey.forEvm(1), Erc7930.encodeEvmChain(1), hubBytes, HOME_SELECTOR)
                )
            )
        );
        spokes[1] = address(
            new ERC1967Proxy(
                address(new CcipZkSyncSpokeTransceiver(router)),
                abi.encodeCall(
                    CcipZkSyncSpokeTransceiver.initialize,
                    (new address[](0), address(0xC0DE), ChainKey.forEvm(1), Erc7930.encodeEvmChain(1), hubBytes, bytes32(uint256(1)), HOME_SELECTOR)
                )
            )
        );
        spokes[2] = address(
            new ERC1967Proxy(
                address(new CcipTronSpokeTransceiver(router)),
                abi.encodeCall(
                    CcipTronSpokeTransceiver.initialize,
                    (new address[](0), address(0xC0DE), ChainKey.forEvm(1), Erc7930.encodeEvmChain(1), hubBytes, bytes32(uint256(1)), HOME_SELECTOR)
                )
            )
        );
    }

    function _otherOrigin() internal pure override returns (uint256) {
        return 4949039107694359620;
    }

    function _deliverFromHubOn(address spoke, uint256 origin) internal override {
        vm.prank(router);
        IAny2EVMMessageReceiver(spoke).ccipReceive(
            Client.Any2EVMMessage({
                messageId: bytes32(0),
                sourceChainSelector: uint64(origin),
                sender: abi.encode(hub),
                data: "",
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }
}
