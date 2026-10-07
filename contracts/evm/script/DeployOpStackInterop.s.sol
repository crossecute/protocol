// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeployProvider} from "script/DeployProvider.s.sol";
import {OpStackInteropDeploy, OpStackInteropConfig} from "script/deploy/OpStackInteropDeploy.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {ChainConfig, ChainEntry} from "script/deploy/ChainConfig.sol";
import {check} from "script/deploy/CrossProxyDeploy.sol";

/// @notice `op-stack-l2-l2`, between OP Stack chains running Superchain interop. No environment
///         inputs of its own. Refuses a chain not in `deploy/providers/op-stack-l2-l2.toml`, and
///         a governor's home not in it either: a transceiver is born accepting only a bootstrap
///         from the home, which has to reach it over this provider. See `DeployProvider`.
contract DeployOpStackInterop is DeployProvider {
    function _providerName() internal pure override returns (string memory) {
        return "op-stack-l2-l2";
    }

    function _implementations() internal override returns (address, address, address) {
        return (
            OpStackInteropDeploy.receiverImplementation(),
            OpStackInteropDeploy.transmitterImplementation(),
            OpStackInteropDeploy.transceiverImplementation()
        );
    }

    function _deploy(TransceiverDeployment memory d) internal override returns (address) {
        string memory dir = ChainConfig.defaultDir();
        ChainEntry[] memory cs = ChainConfig.chains(dir);
        ChainEntry memory local = ChainConfig.chainWithId(cs, block.chainid);
        check(OpStackInteropConfig.isMember(dir, cs, local), "this chain runs op-stack-l2-l2");
        uint256 home = vm.envUint("GOVERNOR_HOME_CHAIN_ID");
        if (home != block.chainid) {
            check(
                OpStackInteropConfig.isMember(dir, cs, ChainConfig.chainWithId(cs, home)),
                "the governor's home reaches this chain over op-stack-l2-l2"
            );
        }
        return OpStackInteropDeploy.transceiver(d);
    }
}
