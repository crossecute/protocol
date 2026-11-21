// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {check} from "script/deploy/ProxyDeploy.sol";
import {ChainConfig, ChainEntry, Derivation} from "script/deploy/ChainConfig.sol";
import {Governance, GovernanceConfig, ChainDeploy} from "script/deploy/ChainDeploy.sol";
import {LzOftDeploy} from "script/deploy/LzOftDeploy.sol";
import {checkReceiverAuthorityDeployment} from "script/deploy/TransceiverDeploy.sol";
import {LzOftConduitFactory} from "src/protocols/layerzero/LzOftConduitFactory.sol";

/// @title DeployLzOft
/// @notice The `layerzero-oft` factory and its logic on this chain. Permissionless: no owner,
///         no mutable configuration and no argument that varies by chain, so anyone deploying them gets
///         the same contracts at the same addresses.
///
/// @dev The factory address commits to the build, receiver authority pins and canonical treasury.
///      `CROSSECUTE_OFT_FACTORY` names the address recorded for the release.
///
/// @dev Only a `parity` chain in `deploy/chains.toml`: elsewhere CREATE2 places the factory, and
///      so every conduit, at another address, or Arachnid's factory is missing.
contract DeployLzOft is Script {
    function run() external returns (LzOftConduitFactory factory) {
        string memory dir = ChainConfig.defaultDir();
        ChainEntry[] memory chains = ChainConfig.chains(dir);
        ChainEntry memory local = ChainConfig.chainWithId(chains, block.chainid);
        check(local.derivation == Derivation.Parity, "layerzero-oft deploys only on a parity chain");
        checkReceiverAuthorityDeployment();
        address treasury = _treasury(chains);
        check(treasury.code.length != 0, "deploy the chain treasury before layerzero-oft");
        LzOftDeploy.requireFactory(treasury, _expectedFactory());
        vm.startBroadcast();
        factory = LzOftDeploy.factory(treasury);
        vm.stopBroadcast();
    }

    /// @notice The factory address to record for the release.
    function predict() external view returns (address) {
        return LzOftDeploy.predictFactory(_treasury(ChainConfig.chains(ChainConfig.defaultDir())));
    }

    function _treasury(ChainEntry[] memory chains) private view returns (address) {
        Governance memory g = GovernanceConfig.read(_governanceFile(), chains);
        GovernanceConfig.requireSet(g);
        return address(ChainDeploy.predict(g).treasury);
    }

    function _expectedFactory() internal view virtual returns (address) {
        return vm.envOr("CROSSECUTE_OFT_FACTORY", address(0));
    }

    function _governanceFile() internal view virtual returns (string memory) {
        return GovernanceConfig.defaultFile();
    }
}
