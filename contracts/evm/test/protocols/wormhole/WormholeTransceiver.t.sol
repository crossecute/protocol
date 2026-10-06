// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {deployTransceiver} from "test/DeployCrossProxy.sol";
import {CoreBridgeVM} from "@wormhole-sdk/interfaces/ICoreBridge.sol";
import {IVaaV1Receiver} from "@wormhole-sdk/interfaces/IExecutor.sol";

import {WormholeTransceiver} from "src/protocols/wormhole/WormholeTransceiver.sol";
import {WormholeZkSyncTransceiver} from "src/protocols/wormhole/WormholeDivergentTransceiver.sol";
import {WormholeReceiver} from "src/protocols/wormhole/WormholeReceiver.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";
import {unseeded} from "test/RegistrySeed.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

import {MockWormholeCore} from "test/protocols/wormhole/MockWormholeCore.sol";
import {MockExecutorQuoterRouter} from "test/protocols/wormhole/MockExecutorQuoterRouter.sol";
import {transceiverConfig, toBytes32} from "test/protocols/ProviderFixture.sol";
import {ProviderGatewayRoleSpec, ProviderGovernorHomeSpec} from "test/protocols/ProviderBindingSpec.t.sol";
import {WormholeFixture, _vaa, _envelope} from "test/protocols/wormhole/WormholeFixture.sol";

/// @notice `executeVAAv1` is permissionless: guardian signatures authenticate the emitter, and
///         the base's counterpart check is what refuses a wrong one.
contract WormholeTransceiverInboundTest is ProviderGatewayRoleSpec, WormholeFixture {
    function _bypassRevert(address) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(WormholeMessage.InvalidVaa.selector, "VM version incompatible");
    }

    function _vaaFrom(address sender, uint16 targetChain, bytes memory message) internal returns (bytes memory) {
        return _vaa(1, BASE_WORMHOLE_CHAIN, sender, sequence++, _envelope(targetChain, transceiver, message));
    }

    function test_aReplayedVaaIsRejected() public {
        _wire();
        bytes memory vaa = _vaaFrom(ORIGIN_TRANSCEIVER, HERE_WORMHOLE_CHAIN, _bootstrap());
        IVaaV1Receiver(transceiver).executeVAAv1(vaa);
        (CoreBridgeVM memory v,,) = core.parseAndVerifyVM(vaa);
        assertTrue(WormholeTransceiver(payable(transceiver)).vaaConsumed(v.hash));
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.VaaAlreadyConsumed.selector, v.hash));
        IVaaV1Receiver(transceiver).executeVAAv1(vaa);
    }

    /// @dev Transceivers share one address across parity chains; a VAA for another chain must
    ///      not run here.
    function test_aVaaForAnotherChainIsRejected() public {
        _wire();
        bytes memory vaa = _vaaFrom(ORIGIN_TRANSCEIVER, 31, _bootstrap());
        vm.expectRevert(
            abi.encodeWithSelector(WormholeMessage.WrongDestination.selector, uint16(31), toBytes32(transceiver))
        );
        IVaaV1Receiver(transceiver).executeVAAv1(vaa);
    }

    function test_aVaaCoreRejectsIsRefused() public {
        _wire();
        core.setInvalid(true);
        bytes memory vaa = _vaaFrom(ORIGIN_TRANSCEIVER, HERE_WORMHOLE_CHAIN, _bootstrap());
        vm.expectRevert(abi.encodeWithSelector(WormholeMessage.InvalidVaa.selector, "VM signature invalid"));
        IVaaV1Receiver(transceiver).executeVAAv1(vaa);
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
                    deployTransceiver(
                        address(new WormholeZkSyncHarness(address(core), address(router), address(0x0907))),
                        abi.encodeCall(
                            WormholeZkSyncTransceiver.initialize,
                            (
                                transceiverConfig(address(new WormholeReceiver(address(core)))),
                                uint16(0),
                                keccak256("zksolc")
                            )
                        )
                    )
                ))
        );
        ChainRegistry registry = new ChainRegistry(address(this), unseeded());
        bytes32 provider = registry.addMessageProvider("wormhole");
        bytes32 home = registry.addChainKey(Erc7930.encodeEvmChain(1), Provenance.Unique);

        vm.startPrank(t.owner());
        t.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Unique);
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
        assertEq(r.dstAddr, toBytes32(address(0xC0DE)), "to its transceiver there");
        assertEq(core.published(0).value + r.paid, 0.011 ether, "the quoted fee, paid from the float");
        assertEq(r.refundAddr, address(t), "an excess returns to the float, not the relayer");
        assertEq(address(t).balance, 0.989 ether);
    }
}

contract WormholeGovernorHomeTest is ProviderGovernorHomeSpec, WormholeFixture {}
