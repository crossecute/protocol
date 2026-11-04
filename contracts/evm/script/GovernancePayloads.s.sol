// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ChainConfig, ChainEntry} from "script/deploy/ChainConfig.sol";
import {PayloadWriter} from "script/deploy/PayloadWriter.sol";
import {Plan, GovernancePlan} from "script/deploy/GovernancePlan.sol";

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
contract GovernancePayloads is PayloadWriter {
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

    function _outDir() internal view virtual override returns (string memory) {
        return string.concat(vm.projectRoot(), "/out/governance");
    }
}
