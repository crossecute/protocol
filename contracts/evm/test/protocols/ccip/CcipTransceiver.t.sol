// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {CcipDeploy} from "script/deploy/CcipDeploy.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import {
    ProviderDivergentSpec,
    ProviderGatewayRoleSpec,
    ProviderGovernorHomeSpec,
    ProviderDeliveryGasSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {CcipFixture, CcipTronHarness, CcipZkSyncHarness} from "test/protocols/ccip/CcipFixture.sol";
import {MockCcipRouter} from "test/protocols/ccip/MockCcipRouter.sol";

contract CcipTransceiverInboundTest is ProviderGatewayRoleSpec, CcipFixture {
    /// @dev Answering false makes the off-ramp mark a message executed without delivering it.
    function test_itAnswersSupportsInterface() public view {
        IERC165 t = IERC165(transceiver);
        assertTrue(t.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(t.supportsInterface(type(IERC165).interfaceId));
        assertFalse(t.supportsInterface(bytes4(0xdeadbeef)));
    }
}

abstract contract CcipDivergentTransceiverSpec is ProviderDivergentSpec, CcipFixture {
    function _assertReportSent() internal view override {
        MockCcipRouter.Sent memory s = router.sent(0);
        assertEq(s.destChainSelector, BASE_SELECTOR, "to the conduit's home");
        assertEq(s.receiver, abi.encode(HOME_TRANSCEIVER), "to its transceiver there");
    }

    function test_itAnswersSupportsInterface() public view {
        assertTrue(IERC165(divergent).supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
    }
}

contract CcipZkSyncTransceiverTest is CcipDivergentTransceiverSpec {
    function _divergentImplementation() internal override returns (address) {
        return address(new CcipZkSyncHarness(address(router)));
    }

    function _deployDivergent(TransceiverDeployment memory d, uint256 homeId) internal override returns (address) {
        return CcipDeploy.zkSyncTransceiver(d, address(router), uint64(homeId), CONDUIT_BYTECODE_HASH);
    }
}

contract CcipTronTransceiverTest is CcipDivergentTransceiverSpec {
    function _divergentImplementation() internal override returns (address) {
        return address(new CcipTronHarness(address(router)));
    }

    function _deployDivergent(TransceiverDeployment memory d, uint256 homeId) internal override returns (address) {
        return CcipDeploy.tronTransceiver(d, address(router), uint64(homeId), CONDUIT_BYTECODE_HASH);
    }
}

contract CcipGovernorHomeTest is ProviderGovernorHomeSpec, CcipFixture {}

contract CcipDeliveryGasTest is ProviderDeliveryGasSpec, CcipFixture {}
