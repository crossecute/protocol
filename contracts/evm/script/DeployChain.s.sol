// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {CrossProxy} from "src/account/CrossProxy.sol";
import {check} from "script/deploy/CrossProxyDeploy.sol";
import {ChainConfig, ChainEntry, Derivation} from "script/deploy/ChainConfig.sol";
import {Governance, GovernanceConfig, ChainContracts, ChainDeploy} from "script/deploy/ChainDeploy.sol";

/// @title DeployChain
/// @notice Step 1 of `docs/provider-spec.md` §6 on one parity chain: its `TimelockController`,
///         `ChainRegistry`, and `Treasury`. Every input is in `deploy/`; any account may
///         broadcast, and a rerun deploys nothing.
contract DeployChain is Script {
    function run() external returns (ChainContracts memory c) {
        ChainEntry[] memory cs = ChainConfig.chains(ChainConfig.defaultDir());
        check(
            ChainConfig.chainWithId(cs, block.chainid).derivation == Derivation.Parity, "this chain is a parity chain"
        );
        Governance memory g = GovernanceConfig.read(_governanceFile(), cs);
        GovernanceConfig.requireSet(g);
        // A build with other settings would deploy transceivers off the record's address (R8.3);
        // refusing here keeps it from reaching step 2 on any chain.
        check(
            keccak256(type(CrossProxy).creationCode) == g.crossProxyInitCodeHash,
            "this build's CrossProxy initcode hash is governance.toml's"
        );

        vm.startBroadcast();
        c = ChainDeploy.deploy(g);
        vm.stopBroadcast();
    }

    /// @dev Overridden by tests, whose file has every value set.
    function _governanceFile() internal view virtual returns (string memory) {
        return GovernanceConfig.defaultFile();
    }
}
