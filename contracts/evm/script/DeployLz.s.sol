// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeployProvider} from "script/DeployProvider.s.sol";
import {LzDeploy} from "script/deploy/LzDeploy.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";

/// @notice `LZ_ENDPOINT`, and `LZ_GOVERNOR_HOME_DVN` where the governor home's pathway defaults
///         to LayerZero's dead DVN (deploy/CHECKS.md §5). See `DeployProvider`.
contract DeployLz is DeployProvider {
    function _providerName() internal pure override returns (string memory) {
        return "layerzero";
    }

    function _implementations() internal override returns (address, address, address) {
        address endpoint = vm.envAddress("LZ_ENDPOINT");
        return (
            LzDeploy.receiverImplementation(endpoint),
            LzDeploy.transmitterImplementation(endpoint),
            LzDeploy.transceiverImplementation(endpoint)
        );
    }

    function _deploy(TransceiverDeployment memory d) internal override returns (address) {
        return LzDeploy.transceiver(d, uint32(_governorHomeId()), vm.envOr("LZ_GOVERNOR_HOME_DVN", address(0)));
    }
}
