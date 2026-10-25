// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {check} from "script/deploy/CrossProxyDeploy.sol";
import {ChainConfig, ChainEntry, Derivation} from "script/deploy/ChainConfig.sol";
import {LzOftDeploy} from "script/deploy/LzOftDeploy.sol";
import {LzOftFactory} from "src/protocols/layerzero/LzOftFactory.sol";

/// @title DeployLzOft
/// @notice The `layerzero-oft` factory and its logic on this chain. Permissionless: no owner,
///         no configuration and no argument that varies by chain, so anyone deploying them gets
///         the same contracts at the same addresses.
///
/// @dev Only a `parity` chain in `deploy/chains.toml`: elsewhere CREATE2 places the factory, and
///      so every account, at another address, or Arachnid's factory is missing.
contract DeployLzOft is Script {
    function run() external returns (LzOftFactory factory) {
        string memory dir = ChainConfig.defaultDir();
        ChainEntry memory local = ChainConfig.chainWithId(ChainConfig.chains(dir), block.chainid);
        check(local.derivation == Derivation.Parity, "layerzero-oft deploys only on a parity chain");
        vm.startBroadcast();
        factory = LzOftDeploy.factory();
        vm.stopBroadcast();
    }
}
