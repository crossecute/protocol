// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeployProvider} from "script/DeployProvider.s.sol";
import {OpStackDeploy, OpStackConfig} from "script/deploy/OpStackDeploy.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {ChainConfig, ChainEntry} from "script/deploy/ChainConfig.sol";
import {check} from "script/deploy/CrossProxyDeploy.sol";

/// @notice `op-stack-l1-l2`, between Ethereum and each OP Stack chain. No environment inputs of
///         its own: the messenger that reaches the governor's home is read from
///         `deploy/providers/op-stack-l1-l2.toml`. See `DeployProvider`.
contract DeployOpStack is DeployProvider {
    function _providerName() internal pure override returns (string memory) {
        return "op-stack-l1-l2";
    }

    function _implementations() internal override returns (address, address, address) {
        return (
            OpStackDeploy.receiverImplementation(),
            OpStackDeploy.transmitterImplementation(),
            OpStackDeploy.transceiverImplementation()
        );
    }

    function _deploy(TransceiverDeployment memory d) internal override returns (address) {
        return OpStackDeploy.transceiver(d, _homeMessenger());
    }

    /// @notice The messenger on this chain that reaches the governor's home. Required unless
    ///         this chain is the home.
    function _homeMessenger() internal view returns (address m) {
        string memory dir = ChainConfig.defaultDir();
        ChainEntry[] memory cs = ChainConfig.chains(dir);
        uint256 home = vm.envUint("GOVERNOR_HOME_CHAIN_ID");
        m = OpStackConfig.messenger(
            dir, cs, ChainConfig.chainWithId(cs, block.chainid), ChainConfig.chainWithId(cs, home)
        );
        if (home != block.chainid) check(m != address(0), "a messenger here reaches the governor's home");
    }
}
