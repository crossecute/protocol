// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CoreBridgeVM} from "@wormhole-sdk/interfaces/ICoreBridge.sol";

import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {WormholeTransceiver} from "src/protocols/wormhole/WormholeTransceiver.sol";
import {WormholeZkSyncTransceiver} from "src/protocols/wormhole/WormholeDivergentTransceiver.sol";
import {WormholeReceiver} from "src/protocols/wormhole/WormholeReceiver.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

import {MockWormholeCore} from "test/protocols/wormhole/MockWormholeCore.sol";
import {MockExecutorQuoterRouter} from "test/protocols/wormhole/MockExecutorQuoterRouter.sol";
import {ProviderInboundSpec} from "test/protocols/ProviderBindingSpec.t.sol";
import {
    WormholeSendSuite,
    UNUSED_EXECUTOR,
    _vaa,
    _envelope,
    _universal
} from "test/protocols/wormhole/WormholeBinding.t.sol";

function wormholeConfig(address coreBridge) returns (TransceiverConfig memory) {
    return TransceiverConfig({
        gateways: new address[](0),
        transmitterImplementation: address(0xBEEF),
        receiverImplementation: address(new WormholeReceiver(coreBridge)),
        governorOwner: address(0x5165),
        governorSalt: bytes32(0),
        governorHome: ChainKey.forEvm(1),
        treasury: address(0x7EA5)
    });
}

/// @notice Exposes the send seam for the shared send suite, and marks each message it handles.
contract WormholeTransceiverHarness is WormholeTransceiver {
    event InboundHandled(bytes32 chainKey);

    constructor(address core, address router, address quoter) WormholeTransceiver(core, router, quoter) {}

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

    function _handleInbound(bytes32 origin, bytes calldata message) internal override {
        emit InboundHandled(origin);
        super._handleInbound(origin, message);
    }
}

function deployWormhole(address core, address router, address quoter) returns (WormholeTransceiverHarness) {
    return WormholeTransceiverHarness(
        payable(address(
                new ERC1967Proxy(
                    address(new WormholeTransceiverHarness(core, router, quoter)),
                    abi.encodeCall(WormholeTransceiver.initialize, (wormholeConfig(core)))
                )
            ))
    );
}

/// @notice `WormholeSendSuite` against the plain transceiver.
contract WormholeTransceiverSendTest is WormholeSendSuite {
    function _deploy() internal override returns (address, address) {
        WormholeTransceiverHarness t = deployWormhole(address(core), address(router), quoter);
        return (address(t), t.owner());
    }
}

/// @notice `executeVAAv1` is permissionless: guardian signatures authenticate the emitter, and
///         the base's counterpart check is what refuses a wrong one.
contract WormholeTransceiverInboundTest is ProviderInboundSpec {
    uint16 constant ORIGIN_WORMHOLE_CHAIN = 30;
    uint16 constant HERE = 2;
    MockWormholeCore core;
    WormholeTransceiverHarness t;
    /// @dev A fresh sequence per VAA, so a second delivery is a new message, not a replay.
    uint64 sequence;

    function setUp() public {
        core = new MockWormholeCore(HERE);
        t = deployWormhole(address(core), UNUSED_EXECUTOR, UNUSED_EXECUTOR);
    }

    function _transceiver() internal view override returns (address) {
        return address(t);
    }

    function _configureOrigin(bytes32 chainKey) internal override {
        vm.prank(t.owner());
        t.setWormholeChain(chainKey, ORIGIN_WORMHOLE_CHAIN);
    }

    function _deliver(address sender, bytes memory message) internal override {
        t.executeVAAv1(_vaaFrom(sender, HERE, message));
    }

    function _vaaFrom(address sender, uint16 targetChain, bytes memory message) internal returns (bytes memory) {
        return _vaa(1, ORIGIN_WORMHOLE_CHAIN, sender, sequence++, _envelope(targetChain, address(t), message));
    }

    /// @dev R6: the receiver names the Core bridge its gateway before its payload runs.
    function _assertReceiverConfigured(address receiver, address) internal view override {
        WormholeReceiver r = WormholeReceiver(payable(receiver));
        assertTrue(r.hasRole(r.GATEWAY_ROLE(), address(core)));
    }

    function test_theCoreBridgeIsTheGatewayWithNoneListed() public view {
        assertTrue(t.hasRole(t.GATEWAY_ROLE(), address(core)));
    }

    function test_aReplayedVaaIsRejected() public {
        _wire();
        bytes memory vaa = _vaaFrom(ORIGIN_TRANSCEIVER, HERE, _bootstrap());
        t.executeVAAv1(vaa);
        (CoreBridgeVM memory v,,) = core.parseAndVerifyVM(vaa);
        assertTrue(t.vaaConsumed(v.hash));
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.VaaAlreadyConsumed.selector, v.hash));
        t.executeVAAv1(vaa);
    }

    /// @dev Transceivers share one address across parity chains; a VAA for another chain must
    ///      not run here.
    function test_aVaaForAnotherChainIsRejected() public {
        _wire();
        bytes memory vaa = _vaaFrom(ORIGIN_TRANSCEIVER, 31, _bootstrap());
        vm.expectRevert(
            abi.encodeWithSelector(WormholeMessage.WrongDestination.selector, uint16(31), _universal(address(t)))
        );
        t.executeVAAv1(vaa);
    }

    function test_aVaaCoreRejectsIsRefused() public {
        _wire();
        core.setInvalid(true);
        bytes memory vaa = _vaaFrom(ORIGIN_TRANSCEIVER, HERE, _bootstrap());
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.InvalidVaa.selector, "VM signature invalid"));
        t.executeVAAv1(vaa);
    }
}

contract WormholeZkSyncHarness is WormholeZkSyncTransceiver {
    constructor(address core, address router, address quoter) WormholeZkSyncTransceiver(core, router, quoter) {}

    function reportPublic(bytes32 home, address owner, bytes32 salt, address receiver) external {
        _reportReceiver(home, owner, salt, receiver);
    }
}

/// @notice A report is sent inside a delivery, at `msg.value == 0`, from the float, and the
///         Executor's excess refund must return to the float, not the relayer.
contract WormholeZkSyncTransceiverTest is Test {
    MockWormholeCore core;
    MockExecutorQuoterRouter router;
    WormholeZkSyncHarness t;
    uint16 constant HOME_WORMHOLE_CHAIN = 2;

    function setUp() public {
        core = new MockWormholeCore(55);
        router = new MockExecutorQuoterRouter();
        t = WormholeZkSyncHarness(
            payable(address(
                    new ERC1967Proxy(
                        address(new WormholeZkSyncHarness(address(core), address(router), address(0x0907))),
                        abi.encodeCall(
                            WormholeZkSyncTransceiver.initialize, (wormholeConfig(address(core)), keccak256("zksolc"))
                        )
                    )
                ))
        );
        ChainRegistry registry = new ChainRegistry(address(this));
        bytes32 provider = registry.addMessageProvider("wormhole");
        bytes32 home = registry.addChainKey(Erc7930.encodeEvmChain(1), Provenance.Attested);

        vm.startPrank(t.owner());
        t.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Attested);
        t.setRoute(home, Erc7930.encodeEvmChain(1));
        t.setCounterpart(home, Erc7930.encodeEvm(1, address(0xC0DE)));
        t.setWormholeChain(home, HOME_WORMHOLE_CHAIN);
        vm.stopPrank();
    }

    function test_itAlwaysDiverges() public view {
        assertTrue(t.addressesDiverge());
    }

    function test_aReportSpendsFromTheFloatAndRefundsToIt() public {
        core.setMessageFee(0.001 ether);
        router.setFee(0.01 ether);
        vm.deal(address(t), 1 ether);

        vm.prank(makeAddr("relayer"));
        t.reportPublic(ChainKey.forEvm(1), address(0xA11CE), bytes32(0), address(0x2C));

        MockExecutorQuoterRouter.Request memory r = router.requests(0);
        assertEq(r.dstChain, HOME_WORMHOLE_CHAIN, "to the account's home");
        assertEq(r.dstAddr, _universal(address(0xC0DE)), "to its transceiver there");
        assertEq(core.published(0).value + r.paid, 0.011 ether, "the quoted fee, paid from the float");
        assertEq(r.refundAddr, address(t), "an excess returns to the float, not the relayer");
        assertEq(address(t).balance, 0.989 ether);
    }
}
