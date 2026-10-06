// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {CcipDeploy} from "script/deploy/CcipDeploy.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAny2EVMMessageReceiver} from "@ccip/interfaces/IAny2EVMMessageReceiver.sol";

import {
    ProviderZkSyncSpec,
    ProviderGatewayRoleSpec,
    ProviderGovernorHomeSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {CcipFixture, CcipZkSyncHarness} from "test/protocols/ccip/CcipFixture.sol";

contract CcipTransceiverInboundTest is ProviderGatewayRoleSpec, CcipFixture {
    /// @dev Answering false makes the off-ramp mark a message executed without delivering it.
    function test_itAnswersSupportsInterface() public view {
        IERC165 t = IERC165(transceiver);
        assertTrue(t.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(t.supportsInterface(type(IERC165).interfaceId));
        assertFalse(t.supportsInterface(bytes4(0xdeadbeef)));
    }
}

contract CcipZkSyncTransceiverTest is ProviderZkSyncSpec, CcipFixture {
    function _zkSyncImplementation() internal override returns (address) {
        return address(new CcipZkSyncHarness(address(router)));
    }

    function _deployZkSync(TransceiverDeployment memory d, bytes32 accountBytecodeHash)
        internal
        override
        returns (address)
    {
        return CcipDeploy.zkSyncTransceiver(d, address(router), 0, accountBytecodeHash);
    }

    function _assertReportSent() internal view override {
        (uint64 selector, bytes memory receiver,,,,) = router.sent(0);
        assertEq(selector, BASE_SELECTOR, "to the account's home");
        assertEq(receiver, abi.encode(HOME_TRANSCEIVER), "to its transceiver there");
    }

    function test_itAnswersSupportsInterface() public view {
        assertTrue(IERC165(zk).supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
    }
}

contract CcipGovernorHomeTest is ProviderGovernorHomeSpec, CcipFixture {}
