// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeployProvider} from "script/DeployProvider.s.sol";
import {CcipDeploy} from "script/deploy/CcipDeploy.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {CcipPreflight} from "script/deploy/CcipPreflight.sol";
import {ChainConfig, ChainEntry} from "script/deploy/ChainConfig.sol";

/// @notice `CCIP_ROUTER`. Refuses to broadcast unless this chain's lanes to and from every other
///         parity chain pass `CcipPreflight`. See `DeployProvider`.
contract DeployCcip is DeployProvider {
    function _providerName() internal pure override returns (string memory) {
        return "ccip";
    }

    function _preflight() internal view override {
        string memory dir = ChainConfig.defaultDir();
        ChainEntry[] memory cs = ChainConfig.chains(dir);
        ChainEntry memory local = ChainConfig.chainWithId(cs, block.chainid);
        CcipPreflight.require_(CcipPreflight.problems(dir, cs, local, vm.envAddress("CCIP_ROUTER")));
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
        return CcipDeploy.transceiver(d, vm.envAddress("CCIP_ROUTER"), uint64(_governorHomeId()));
    }
}
