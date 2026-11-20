// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeployProvider} from "script/DeployProvider.s.sol";
import {LzDeploy} from "script/deploy/LzDeploy.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {ChainConfig, ChainEntry} from "script/deploy/ChainConfig.sol";

/// @notice `LZ_ENDPOINT`. The DVN for the governor home's pathway comes from
///         `providers/layerzero.toml`, set only where that pathway defaults to LayerZero's dead
///         DVN (deploy/CHECKS.md §5). See `DeployProvider`.
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
        string memory dir = ChainConfig.defaultDir();
        ChainEntry[] memory cs = ChainConfig.chains(dir);
        ChainEntry memory local = ChainConfig.chainWithId(cs, block.chainid);
        ChainEntry memory home = _governance().home;
        address homeDvn = local.chainId == home.chainId ? address(0) : ChainConfig.lzDvn(dir, cs, local, home);
        return LzDeploy.transceiver(d, uint32(_governorHomeId()), homeDvn);
    }
}
