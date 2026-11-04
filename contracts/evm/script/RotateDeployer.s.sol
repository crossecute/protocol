// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ChainConfig, ChainEntry} from "script/deploy/ChainConfig.sol";
import {DeployCheck, check} from "script/deploy/CrossProxyDeploy.sol";
import {PayloadWriter} from "script/deploy/PayloadWriter.sol";
import {Tx, Plan, PendingPair, GovernancePlan} from "script/deploy/GovernancePlan.sol";
import {GovernanceConfig} from "script/deploy/ChainDeploy.sol";

/// @title RotateDeployer
/// @notice Writes the rotation of the deployer, for every parity chain in `deploy/chains.toml`, to
///         `out/rotation/` as Safe Transaction Builder batches, numbered in the order they are
///         submitted (`deploy/README.md`, "Rotating the deployer"):
///
///         1. `1-schedule-home.json`, by the governor's owner: `setCurrentDeployer` and any
///            `rekeyPending`, scheduled on the home's timelock;
///         2. `2-schedule-remote.json`, by the governor's owner: the same operation scheduled on
///            every other chain, one message each;
///         3. `3-execute-<chain>.json`, by anyone on each chain once its delay has passed.
///
/// @dev From the environment: `NEW_DEPLOYER`, and `PENDING_CHAINS` with `PENDING_PROVIDERS`, two
///      equal-length comma-separated lists of the chain and provider names (as in `deploy/`) of each
///      pair that is `Pending` in the registries. A pair that is `Live` cannot be re-keyed, and
///      this script reads nothing on chain, so naming the pairs is the operator's.
///
/// @dev Covers chains the first deployer deployed, the ones `GovernancePayloads` configures: the
///      governor's receivers there are at the addresses `governance.toml` predicts. It rotates away
///      from `governance.toml`'s `deployed_by`; a second rotation needs the generation that
///      deployed each chain ([todo §3](../../docs/todo.md#3-infrastructure)).
contract RotateDeployer is PayloadWriter {
    function run() external {
        address newDeployer = _newDeployer();
        Plan memory p = GovernancePlan.load(ChainConfig.defaultDir(), _governanceFile());
        check(newDeployer != address(0), "NEW_DEPLOYER is set");
        check(newDeployer != p.g.deployer, "NEW_DEPLOYER is not governance.toml's deployed_by");
        PendingPair[] memory pending = _pending(p);

        string memory dir = _outDir();
        vm.createDir(dir, true);
        uint256 home = p.g.home.chainId;
        address owner = p.g.owner;

        _write(dir, "1-schedule-home", home, owner, GovernancePlan.rotateHome(p, newDeployer, pending));
        _write(dir, "2-schedule-remote", home, owner, GovernancePlan.rotateRemote(p, newDeployer, pending));
        Tx[] memory execute = new Tx[](1);
        execute[0] = GovernancePlan.executeRotation(p, newDeployer, pending);
        for (uint256 i; i < p.chains.length; ++i) {
            _write(dir, string.concat("3-execute-", p.chains[i].name), p.chains[i].chainId, address(0), execute);
        }
    }

    function _outDir() internal view virtual override returns (string memory) {
        return string.concat(vm.projectRoot(), "/out/rotation");
    }

    /// @dev Overridden by tests, which cannot set the process-wide environment without racing.
    function _newDeployer() internal view virtual returns (address) {
        return vm.envAddress("NEW_DEPLOYER");
    }

    function _pendingChains() internal view virtual returns (string[] memory) {
        return vm.envOr("PENDING_CHAINS", ",", new string[](0));
    }

    function _pendingProviders() internal view virtual returns (string[] memory) {
        return vm.envOr("PENDING_PROVIDERS", ",", new string[](0));
    }

    /// @dev Each named chain must be a configured parity chain and each provider one that
    ///      `governance.toml` lists and that was deployed on that chain.
    function _pending(Plan memory p) internal view returns (PendingPair[] memory pairs) {
        string[] memory chains = _pendingChains();
        string[] memory providers = _pendingProviders();
        check(chains.length == providers.length, "PENDING_CHAINS and PENDING_PROVIDERS pair up");
        pairs = new PendingPair[](chains.length);
        for (uint256 i; i < chains.length; ++i) {
            ChainEntry memory chain = _chainNamed(p, chains[i]);
            GovernanceConfig.providerSeed(p.g, providers[i]);
            check(GovernancePlan.isOn(p, providers[i], chain), "a pending pair names a provider deployed on the chain");
            pairs[i] = PendingPair({chainId: chain.chainId, provider: providers[i]});
        }
    }

    function _chainNamed(Plan memory p, string memory name) private pure returns (ChainEntry memory) {
        for (uint256 i; i < p.chains.length; ++i) {
            if (keccak256(bytes(p.chains[i].name)) == keccak256(bytes(name))) return p.chains[i];
        }
        revert DeployCheck("a pending pair names a parity chain in chains.toml");
    }
}
