// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";

import {WormholeHubTransceiver} from "src/protocols/wormhole/WormholeHubTransceiver.sol";
import {WormholeSpokeTransceiver} from "src/protocols/wormhole/WormholeSpokeTransceiver.sol";
import {WormholeReceiver} from "src/protocols/wormhole/WormholeReceiver.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";
import {RequestLib} from "@wormhole-sdk/Executor/Request.sol";
import {CoreBridgeVM} from "@wormhole-sdk/interfaces/ICoreBridge.sol";

import {MockWormholeCore} from "test/protocols/wormhole/MockWormholeCore.sol";
import {MockExecutorQuoterRouter} from "test/protocols/wormhole/MockExecutorQuoterRouter.sol";
import {ProviderHubSendSpec, IHubSendHarness, ProviderReceiveSpec} from "test/protocols/ProviderBindingSpec.t.sol";

/// @notice Exposes `_sendMessage`/`_quoteMessage` directly (bootstrap/ownership machinery is
///         covered by `test/Transport.t.sol`).
contract WormholeHubHarness is WormholeHubTransceiver {
    constructor(address core, address router, address quoter) WormholeHubTransceiver(core, router, quoter) {}

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

function _universal(address a) pure returns (bytes32) {
    return bytes32(uint256(uint160(a)));
}

/// @dev VAA v1 with `sigCount` zeroed 66-byte signatures (the mock Core does not check them)
///      and a payload already wrapped in the binding's destination envelope.
function _vaa(uint8 sigCount, uint16 emitterChain, address emitter, uint64 sequence, bytes memory payload)
    pure
    returns (bytes memory)
{
    return abi.encodePacked(
        uint8(1),
        uint32(0),
        sigCount,
        new bytes(uint256(sigCount) * 66),
        uint32(1_700_000_000),
        uint32(0),
        emitterChain,
        _universal(emitter),
        sequence,
        uint8(1),
        payload
    );
}

function _envelope(uint16 targetChain, address target, bytes memory inner) pure returns (bytes memory) {
    return abi.encodePacked(targetChain, _universal(target), inner);
}

contract WormholeSendTest is ProviderHubSendSpec {
    MockWormholeCore core;
    MockExecutorQuoterRouter router;
    WormholeHubHarness hub;
    address msig = address(0x5165);
    address quoter = address(0x0907);
    uint16 constant HOME_WORMHOLE_CHAIN = 2;
    uint16 constant BASE_WORMHOLE_CHAIN = 30;

    function setUp() public {
        core = new MockWormholeCore(HOME_WORMHOLE_CHAIN);
        router = new MockExecutorQuoterRouter();
        hub = WormholeHubHarness(
            address(
                new ERC1967Proxy(
                    address(new WormholeHubHarness(address(core), address(router), quoter)),
                    abi.encodeCall(
                        WormholeHubTransceiver.initialize, (msig, address(0), new address[](0), address(0xBEEF))
                    )
                )
            )
        );
        harness = IHubSendHarness(address(hub));

        vm.prank(msig);
        hub.setWormholeChain(ChainKey.forEvm(8453), BASE_WORMHOLE_CHAIN);
    }

    function _configuredRecipient() internal pure override returns (bytes memory) {
        return Erc7930.encodeEvm(8453, address(0xC0DE));
    }

    function _unconfiguredRecipient() internal pure override returns (bytes memory) {
        return Erc7930.encodeEvm(1, address(0xC0DE));
    }

    function _setProviderFee(uint256 fee) internal override {
        router.setFee(fee);
    }

    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(router.requestsLength(), 1);
        assertEq(router.requests(0).dstChain, BASE_WORMHOLE_CHAIN);
    }

    function _gasLimitAttribute(uint256 gasLimit) internal view returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(hub.WORMHOLE_GAS_LIMIT_ATTRIBUTE(), gasLimit);
    }

    function test_publishedPayloadNamesItsDestination() public {
        hub.sendMessagePublic(_configuredRecipient(), "payload", new bytes[](0), 0);
        MockWormholeCore.Published memory p = core.published(0);
        assertEq(p.emitter, address(hub));
        assertEq(p.payload, _envelope(BASE_WORMHOLE_CHAIN, address(0xC0DE), "payload"));
        assertEq(p.consistencyLevel, 1);
    }

    function test_executionRequestNamesTheVaaAndTheRecipient() public {
        address payer = address(0xFEE);
        vm.prank(payer);
        hub.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        MockExecutorQuoterRouter.Request memory r = router.requests(0);
        assertEq(r.dstAddr, _universal(address(0xC0DE)));
        assertEq(r.refundAddr, payer);
        assertEq(r.quoterAddr, quoter);
        assertEq(r.requestBytes, RequestLib.encodeVaaMultiSigRequest(HOME_WORMHOLE_CHAIN, _universal(address(hub)), 0));
    }

    function test_gasLimitDefaultsAndFollowsTheAttribute() public {
        hub.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        hub.sendMessagePublic(_configuredRecipient(), "x", _gasLimitAttribute(750_000), 0);
        assertEq(router.requests(0).relayInstructions, abi.encodePacked(uint8(1), uint128(200_000), uint128(0)));
        assertEq(router.requests(1).relayInstructions, abi.encodePacked(uint8(1), uint128(750_000), uint128(0)));
    }

    function test_quoteIsMessageFeePlusExecutionPrice() public {
        core.setMessageFee(0.001 ether);
        router.setFee(0.01 ether);
        assertEq(hub.quoteMessagePublic(_configuredRecipient(), "x"), 0.011 ether);
    }

    function test_valueSplitsBetweenCoreAndTheRouterWithExcessRefunded() public {
        core.setMessageFee(0.001 ether);
        router.setFee(0.01 ether);
        address payer = address(0xFEE);
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        hub.sendMessagePublic{value: 0.03 ether}(_configuredRecipient(), "x", new bytes[](0), 0.03 ether);
        assertEq(core.published(0).value, 0.001 ether);
        assertEq(router.requests(0).paid, 0.01 ether);
        assertEq(payer.balance, 0.989 ether);
        assertEq(address(hub).balance, 0);
    }

    function test_valueBelowTheMessageFeeIsRefused() public {
        core.setMessageFee(0.001 ether);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(WormholeMessage.InsufficientWormholeValue.selector, 0.0005 ether, 0.001 ether)
        );
        hub.sendMessagePublic{value: 0.0005 ether}(_configuredRecipient(), "x", new bytes[](0), 0.0005 ether);
    }

    function test_gasLimitAboveUint128IsRefused() public {
        bytes[] memory attrs = _gasLimitAttribute(uint256(type(uint128).max) + 1);
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        hub.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    /// @dev A malformed first attribute is reported even when an extra follows it.
    function test_malformedFirstAttributeIsReportedBeforeAnExtra() public {
        bytes[] memory attrs = new bytes[](2);
        attrs[0] = abi.encodePacked(bytes4(0xdeadbeef), uint256(1));
        attrs[1] = abi.encodePacked(hub.WORMHOLE_GAS_LIMIT_ATTRIBUTE(), uint256(1));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        hub.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_unknownAttributeIsRefused() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(bytes4(0xdeadbeef), uint256(1));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        hub.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_nonEvmWidthRecipientIsRefused() public {
        bytes memory wide = abi.encodePacked(bytes32(uint256(0xC0DE)));
        bytes memory recipient = Erc7930.encode(Erc7930.CT_EIP155, Erc7930.minimalBigEndian(8453), wide);
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.UnsupportedWormholeRecipient.selector, wide));
        hub.sendMessagePublic(recipient, "x", new bytes[](0), 0);
    }
}

/// @notice `executeVAAv1` is permissionless: guardian signatures (checked by Core) authenticate
///         the emitter, and `isSourceTransmitter` is the only sender check.
contract WormholeReceiveTest is ProviderReceiveSpec {
    MockWormholeCore core;
    WormholeReceiver receiver;
    address sourceTransmitter = address(0xABCD);
    uint16 constant HOME = 2;
    uint16 constant HERE = 30;

    function setUp() public {
        core = new MockWormholeCore(HERE);
        receiver = WormholeReceiver(
            payable(address(
                    new ERC1967Proxy(
                        address(new WormholeReceiver(address(core))),
                        abi.encodeCall(WormholeReceiver.initialize, (sourceTransmitter, new Call[](0)))
                    )
                ))
        );
    }

    function _validVaa(uint64 sequence) internal view returns (bytes memory) {
        return _vaa(
            1, HOME, sourceTransmitter, sequence, _envelope(HERE, address(receiver), Payload.encodeCalls(new Call[](0)))
        );
    }

    function _receiverUnderTest() internal view override returns (address) {
        return address(receiver);
    }

    function _deliverFromConfiguredSource() internal override {
        vm.prank(address(0xE1EC));
        receiver.executeVAAv1(_validVaa(0));
    }

    function _deliverFromImpersonator() internal override {
        receiver.executeVAAv1(_vaa(1, HOME, address(0xBAD), 0, _envelope(HERE, address(receiver), "")));
    }

    /// @dev `WormholeReceiver` keeps no origin state (same as `CcipReceiver`), so the
    ///      unconfigured-origin case is the impersonator case.
    function _deliverFromUnconfiguredOrigin() internal override {
        receiver.executeVAAv1(_vaa(1, 99, address(0xBAD), 0, _envelope(HERE, address(receiver), "")));
    }

    /// @dev There is no privileged caller to bypass: the equivalent is a VAA Core rejects.
    function _deliverFromWrongCaller() internal override {
        bytes memory vaa = _validVaa(0);
        vaa[0] = 0x02;
        receiver.executeVAAv1(vaa);
    }

    function test_aReplayedVaaIsRejected() public {
        bytes memory vaa = _validVaa(0);
        receiver.executeVAAv1(vaa);
        (CoreBridgeVM memory v,,) = core.parseAndVerifyVM(vaa);
        bytes32 hash = v.hash;
        assertTrue(receiver.vaaConsumed(hash));
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.VaaAlreadyConsumed.selector, hash));
        receiver.executeVAAv1(vaa);
    }

    /// @dev Receivers share one address across parity chains; a VAA for another chain must not
    ///      run here.
    function test_aVaaForAnotherChainIsRejected() public {
        bytes memory vaa =
            _vaa(1, HOME, sourceTransmitter, 0, _envelope(31, address(receiver), Payload.encodeCalls(new Call[](0))));
        vm.expectRevert(
            abi.encodeWithSelector(WormholeMessage.WrongDestination.selector, uint16(31), _universal(address(receiver)))
        );
        receiver.executeVAAv1(vaa);
    }

    function test_aVaaForAnotherAddressIsRejected() public {
        bytes memory vaa =
            _vaa(1, HOME, sourceTransmitter, 0, _envelope(HERE, address(0xD1FF), Payload.encodeCalls(new Call[](0))));
        vm.expectRevert(
            abi.encodeWithSelector(WormholeMessage.WrongDestination.selector, HERE, _universal(address(0xD1FF)))
        );
        receiver.executeVAAv1(vaa);
    }

    /// @dev `revokeGateway(coreBridge)` must still disconnect Wormhole even though the Core
    ///      bridge never calls in.
    function test_revokingTheCoreBridgeGatewayDisconnectsWormhole() public {
        vm.prank(sourceTransmitter);
        receiver.revokeGateway(address(core));
        vm.expectRevert(WormholeMessage.WormholeGatewayRevoked.selector);
        receiver.executeVAAv1(_validVaa(0));
    }

    function test_aPayloadDifferentFromWhatCoreVerifiedIsRejected() public {
        core.setPayloadOverride("something else");
        vm.expectRevert(WormholeMessage.MalformedVaa.selector);
        receiver.executeVAAv1(_validVaa(0));
    }

    function test_signatureCountSetsThePayloadOffset() public {
        vm.expectEmit(false, false, false, true, address(receiver));
        emit Delivered(0);
        receiver.executeVAAv1(
            _vaa(13, HOME, sourceTransmitter, 0, _envelope(HERE, address(receiver), Payload.encodeCalls(new Call[](0))))
        );
    }

    function test_nonzeroValueIsRejected() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(WormholeMessage.UnexpectedValue.selector);
        receiver.executeVAAv1{value: 1}(_validVaa(0));
    }

    function test_receiverGrantsTheCoreBridgeTheGatewayRole() public view {
        assertTrue(receiver.hasRole(receiver.GATEWAY_ROLE(), address(core)));
    }
}

contract WormholeTransceiverReceiveTest is Test {
    MockWormholeCore core;
    WormholeSpokeTransceiver spoke;
    WormholeHubTransceiver hub;
    uint16 constant HOME = 2;
    uint16 constant HERE = 30;
    address homeTransceiver = address(0xD00D);

    function setUp() public {
        core = new MockWormholeCore(HERE);
        spoke = WormholeSpokeTransceiver(
            address(
                new ERC1967Proxy(
                    address(new WormholeSpokeTransceiver(address(core), address(0), address(0))), _spokeInit(HOME)
                )
            )
        );
        hub = WormholeHubTransceiver(
            address(
                new ERC1967Proxy(
                    address(new WormholeHubTransceiver(address(core), address(0), address(0))),
                    abi.encodeCall(
                        WormholeHubTransceiver.initialize,
                        (address(this), address(0), new address[](0), address(0xBEEF))
                    )
                )
            )
        );
    }

    function _spokeInit(uint16 homeWormholeChain) internal view returns (bytes memory) {
        return abi.encodeCall(
            WormholeSpokeTransceiver.initialize,
            (
                new address[](0),
                address(0xC0DE),
                ChainKey.forEvm(1),
                Erc7930.encodeEvmChain(1),
                abi.encodePacked(homeTransceiver),
                homeWormholeChain
            )
        );
    }

    function test_hubAndSpokeGrantTheCoreBridgeTheGatewayRole() public view {
        assertTrue(hub.hasRole(hub.GATEWAY_ROLE(), address(core)));
        assertTrue(spoke.hasRole(spoke.GATEWAY_ROLE(), address(core)));
    }

    function test_spokeRejectsZeroHomeWormholeChain() public {
        address impl = address(new WormholeSpokeTransceiver(address(core), address(0), address(0)));
        vm.expectRevert(WormholeSpokeTransceiver.ZeroHomeWormholeChain.selector);
        new ERC1967Proxy(impl, _spokeInit(0));
    }

    /// @dev The hub's own address, emitting from any chain but home, is not the hub.
    function test_spokeRejectsTheHubsAddressFromAnotherChain() public {
        bytes memory vaa = _vaa(1, 5, homeTransceiver, 0, _envelope(HERE, address(spoke), ""));
        vm.expectRevert(abi.encodeWithSelector(WormholeSpokeTransceiver.UnexpectedEmitterChain.selector, 5));
        spoke.executeVAAv1(vaa);
    }

    function test_spokeRejectsANonHubEmitterFromHome() public {
        bytes memory vaa = _vaa(1, HOME, address(0xBAD), 0, _envelope(HERE, address(spoke), ""));
        vm.expectRevert();
        spoke.executeVAAv1(vaa);
    }

    function test_spokeRejectsAVaaForAnotherSpoke() public {
        bytes memory vaa = _vaa(1, HOME, homeTransceiver, 0, _envelope(31, address(spoke), ""));
        vm.expectRevert(
            abi.encodeWithSelector(WormholeMessage.WrongDestination.selector, uint16(31), _universal(address(spoke)))
        );
        spoke.executeVAAv1(vaa);
    }

    function test_hubRejectsAnUnmappedEmitterChain() public {
        bytes memory vaa = _vaa(1, 999, address(0xC0DE), 0, _envelope(HERE, address(hub), ""));
        vm.expectRevert(abi.encodeWithSelector(ProviderChainId.UnknownProviderId.selector, uint256(999)));
        hub.executeVAAv1(vaa);
    }

    function test_hubRejectsAnInvalidVaa() public {
        core.setInvalid(true);
        bytes memory vaa = _vaa(1, 5, address(0xC0DE), 0, _envelope(HERE, address(hub), ""));
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.InvalidVaa.selector, "VM signature invalid"));
        hub.executeVAAv1(vaa);
    }
}
