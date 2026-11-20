// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

function createRpcFork(Vm vm, string memory rpc, string memory blockVariable) returns (uint256) {
    uint256 forkBlock = vm.envOr(blockVariable, uint256(0));
    if (forkBlock == 0) return vm.createFork(rpc);
    return vm.createFork(rpc, forkBlock);
}
