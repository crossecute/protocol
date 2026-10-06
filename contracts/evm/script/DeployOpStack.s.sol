// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DeployProvider} from "script/DeployProvider.s.sol";
import {OpStackDeploy} from "script/deploy/OpStackDeploy.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";

/// @notice `OP_STACK_MESSENGER`, and `OP_STACK_PAIRED_CHAIN_ID`: the chain at the other end of
///         that messenger. See `DeployProvider`.
contract DeployOpStack is DeployProvider {
    function _providerName() internal pure override returns (string memory) {
        return "op-stack";
    }

    function _implementations() internal override returns (address, address, address) {
        address messenger = vm.envAddress("OP_STACK_MESSENGER");
        return (
            OpStackDeploy.receiverImplementation(messenger),
            OpStackDeploy.transmitterImplementation(),
            OpStackDeploy.transceiverImplementation(messenger, _paired())
        );
    }

    function _deploy(TransceiverDeployment memory d) internal override returns (address) {
        return OpStackDeploy.transceiver(d, vm.envAddress("OP_STACK_MESSENGER"), _paired());
    }

    function _paired() internal view returns (bytes32) {
        return ChainKey.forEvm(vm.envUint("OP_STACK_PAIRED_CHAIN_ID"));
    }
}
