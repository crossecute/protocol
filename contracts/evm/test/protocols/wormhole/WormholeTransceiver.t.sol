// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {WormholeDeploy} from "script/deploy/WormholeDeploy.sol";
import {CoreBridgeVM} from "@wormhole-sdk/interfaces/ICoreBridge.sol";
import {IVaaV1Receiver} from "@wormhole-sdk/interfaces/IExecutor.sol";

import {WormholeTransceiver} from "src/protocols/wormhole/WormholeTransceiver.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";

import {MockExecutorQuoterRouter} from "test/protocols/wormhole/MockExecutorQuoterRouter.sol";
import {toBytes32} from "test/protocols/ProviderFixture.sol";
import {
    ProviderZkSyncSpec,
    ProviderGatewayRoleSpec,
    ProviderGovernorHomeSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {WormholeFixture, WormholeZkSyncHarness, _vaa, _envelope} from "test/protocols/wormhole/WormholeFixture.sol";

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

contract WormholeZkSyncTransceiverTest is ProviderZkSyncSpec, WormholeFixture {
    function _zkSyncImplementation() internal override returns (address) {
        return address(new WormholeZkSyncHarness(address(core), address(router), QUOTER));
    }

    function _deployZkSync(TransceiverDeployment memory d, bytes32 accountBytecodeHash)
        internal
        override
        returns (address)
    {
        return WormholeDeploy.zkSyncTransceiver(d, address(core), 0, accountBytecodeHash);
    }

    function _assertReportSent() internal view override {
        MockExecutorQuoterRouter.Request memory r = router.requests(0);
        assertEq(r.dstChain, BASE_WORMHOLE_CHAIN, "to the account's home");
        assertEq(r.dstAddr, toBytes32(HOME_TRANSCEIVER), "to its transceiver there");
        assertEq(r.refundAddr, zk, "an excess returns to the float, not the relayer");
    }
}

contract WormholeGovernorHomeTest is ProviderGovernorHomeSpec, WormholeFixture {}
