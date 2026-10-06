// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeployProvider} from "script/DeployProvider.s.sol";
import {HyperlaneDeploy} from "script/deploy/HyperlaneDeploy.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";

/// @notice `HYPERLANE_MAILBOX`, and `HYPERLANE_GOVERNOR_HOME_DOMAIN`. See `DeployProvider`.
contract DeployHyperlane is DeployProvider {
    function _providerName() internal pure override returns (string memory) {
        return "hyperlane";
    }

    function _implementations() internal override returns (address, address, address) {
        address mailbox = vm.envAddress("HYPERLANE_MAILBOX");
        return (
            HyperlaneDeploy.receiverImplementation(mailbox),
            HyperlaneDeploy.transmitterImplementation(mailbox),
            HyperlaneDeploy.transceiverImplementation(mailbox)
        );
    }

    function _deploy(TransceiverDeployment memory d) internal override returns (address) {
        return HyperlaneDeploy.transceiver(
            d, vm.envAddress("HYPERLANE_MAILBOX"), uint32(_governorHomeId("HYPERLANE_GOVERNOR_HOME_DOMAIN"))
        );
    }
}
