// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {ChainConfig, ChainEntry} from "script/deploy/ChainConfig.sol";
import {GovernanceConfig} from "script/deploy/ChainDeploy.sol";
import {Plan, Tx, GovernancePlan} from "script/deploy/GovernancePlan.sol";

/// @title GovernancePayloads
/// @notice Writes steps 3 to 6 of `docs/provider-spec.md` §6 to `out/governance/` as Safe
///         Transaction Builder batches, numbered in the order they are submitted:
///
///         1. `1-prepare-home.json`, by the governor's owner on the home;
///         2. `2-execute-registry-<home>.json`, by anyone on the home after the timelock delay;
///         3. `3-bootstrap.json`, by the governor's owner, once each transmitter holds its quotes;
///         4. `4-execute-registry-<chain>.json`, by anyone on each other chain after its delay;
///         5. `5-connect.json`, by the governor's owner, once every file 4 has executed.
///
/// @dev Reads `deploy/` and nothing on chain, so a commit always yields the same files, which
///      `forge-attest` can pin. `createdAt` is zero for the same reason.
contract GovernancePayloads is Script {
    function run() external {
        Plan memory p = GovernancePlan.load(ChainConfig.defaultDir(), _governanceFile());
        string memory dir = _outDir();
        vm.createDir(dir, true);
        uint256 home = p.g.home.chainId;
        address owner = p.g.owner;

        _write(dir, "1-prepare-home", home, owner, GovernancePlan.prepareHome(p));
        _write(
            dir,
            string.concat("2-execute-registry-", p.g.home.name),
            home,
            address(0),
            _one(GovernancePlan.executeRegistry(p, p.g.home))
        );
        _write(dir, "3-bootstrap", home, owner, GovernancePlan.bootstrap(p));
        for (uint256 i; i < p.chains.length; ++i) {
            ChainEntry memory x = p.chains[i];
            if (x.chainId == home) continue;
            _write(
                dir,
                string.concat("4-execute-registry-", x.name),
                x.chainId,
                address(0),
                _one(GovernancePlan.executeRegistry(p, x))
            );
        }
        _write(dir, "5-connect", home, owner, GovernancePlan.connect(p));
    }

    /// @dev Overridden by tests, whose file has every value set.
    function _governanceFile() internal view virtual returns (string memory) {
        return GovernanceConfig.defaultFile();
    }

    function _outDir() internal view virtual returns (string memory) {
        return string.concat(vm.projectRoot(), "/out/governance");
    }

    function _write(string memory dir, string memory name, uint256 chainId, address safe, Tx[] memory txs) internal {
        // forge-lint: disable-next-line(unsafe-cheatcode) writes the batches under out/governance
        vm.writeFile(string.concat(dir, "/", name, ".json"), batchJson(name, chainId, safe, txs));
    }

    /// @notice The Transaction Builder format: `meta.createdFromSafeAddress` binds a batch to the
    ///         governor's owner, and is left out of one anyone may submit.
    function batchJson(string memory name, uint256 chainId, address safe, Tx[] memory txs)
        public
        pure
        returns (string memory json)
    {
        string memory meta = string.concat('{"name":"', name, '","description":""');
        if (safe != address(0)) meta = string.concat(meta, ',"createdFromSafeAddress":"', vm.toString(safe), '"');
        json = string.concat(
            '{"version":"1.0","chainId":"', vm.toString(chainId), '","createdAt":0,"meta":', meta, '},"transactions":['
        );
        for (uint256 i; i < txs.length; ++i) {
            json = string.concat(
                json,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(txs[i].to),
                '","value":"',
                vm.toString(txs[i].value),
                '","data":"',
                vm.toString(txs[i].data),
                '","operation":"0"}'
            );
        }
        json = string.concat(json, "]}");
    }

    function _one(Tx memory t) private pure returns (Tx[] memory txs) {
        txs = new Tx[](1);
        txs[0] = t;
    }
}
