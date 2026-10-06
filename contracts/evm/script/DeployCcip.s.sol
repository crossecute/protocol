// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeployProvider} from "script/DeployProvider.s.sol";
import {CcipDeploy} from "script/deploy/CcipDeploy.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";

/// @notice `CCIP_ROUTER`, and `CCIP_GOVERNOR_HOME_SELECTOR`. See `DeployProvider`.
contract DeployCcip is DeployProvider {
    function _providerName() internal pure override returns (string memory) {
        return "ccip";
    }

    function _implementations() internal override returns (address, address, address) {
        address router = vm.envAddress("CCIP_ROUTER");
        return (
            CcipDeploy.receiverImplementation(router),
            CcipDeploy.transmitterImplementation(router),
            CcipDeploy.transceiverImplementation(router)
        );
    }

    function _deploy(TransceiverDeployment memory d) internal override returns (address) {
        return
            CcipDeploy.transceiver(
                d, vm.envAddress("CCIP_ROUTER"), uint64(_governorHomeId("CCIP_GOVERNOR_HOME_SELECTOR"))
            );
    }
}
