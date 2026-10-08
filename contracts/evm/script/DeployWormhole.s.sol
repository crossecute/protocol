// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeployProvider} from "script/DeployProvider.s.sol";
import {WormholeDeploy} from "script/deploy/WormholeDeploy.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";

/// @notice `WORMHOLE_CORE` and `WORMHOLE_EXECUTOR`. See `DeployProvider`.
contract DeployWormhole is DeployProvider {
    function _providerName() internal pure override returns (string memory) {
        return "wormhole";
    }

    function _endpoints() internal view returns (WormholeDeploy.Endpoints memory) {
        return WormholeDeploy.Endpoints({
            coreBridge: vm.envAddress("WORMHOLE_CORE"), executor: vm.envAddress("WORMHOLE_EXECUTOR")
        });
    }

    function _implementations() internal override returns (address, address, address) {
        WormholeDeploy.Endpoints memory e = _endpoints();
        return (
            WormholeDeploy.receiverImplementation(e),
            WormholeDeploy.transmitterImplementation(e),
            WormholeDeploy.transceiverImplementation(e)
        );
    }

    function _deploy(TransceiverDeployment memory d) internal override returns (address) {
        return WormholeDeploy.transceiver(d, vm.envAddress("WORMHOLE_CORE"), uint16(_governorHomeId()));
    }
}
