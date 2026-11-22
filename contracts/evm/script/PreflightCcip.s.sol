// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {check} from "script/deploy/ProxyDeploy.sol";
import {CcipPreflight} from "script/deploy/CcipPreflight.sol";
import {ChainConfig, ChainEntry, Derivation} from "script/deploy/ChainConfig.sol";

/// @title PreflightCcip
/// @notice Read-only `CcipPreflight` on every parity chain CCIP reaches, so each directional route
///         is checked at both of its ends before any chain deploys. Broadcasts nothing.
/// @dev Per chain `<NAME>` (its `chains.toml` name, upper-cased, `-` as `_`): `RPC_URL_<NAME>`
///      and `CCIP_ROUTER_<NAME>`, the router `deploy/CHECKS.md` records. Set `FORK_BLOCK_<NAME>`
///      to check historical state. Failures from every chain are reported together.
contract PreflightCcip is Script {
    function run() external {
        string memory dir = ChainConfig.defaultDir();
        ChainEntry[] memory cs = ChainConfig.chains(dir);
        string memory found;
        for (uint256 i; i < cs.length; ++i) {
            if (cs[i].derivation != Derivation.Parity || ChainConfig.providerId(dir, cs, "ccip", cs[i]) == 0) continue;
            string memory name = vm.replace(vm.toUppercase(cs[i].name), "-", "_");
            string memory rpc = vm.envString(string.concat("RPC_URL_", name));
            uint256 forkBlock = vm.envOr(string.concat("FORK_BLOCK_", name), uint256(0));
            if (forkBlock == 0) vm.createSelectFork(rpc);
            else vm.createSelectFork(rpc, forkBlock);
            check(block.chainid == cs[i].chainId, "RPC_URL_<NAME> serves that chain");
            address router = vm.envAddress(string.concat("CCIP_ROUTER_", name));
            found = CcipPreflight.join(found, CcipPreflight.problems(dir, cs, cs[i], router));
        }
        CcipPreflight.require_(found);
    }
}
