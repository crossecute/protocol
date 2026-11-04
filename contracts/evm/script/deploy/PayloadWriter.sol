// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {GovernanceConfig} from "script/deploy/ChainDeploy.sol";
import {Tx} from "script/deploy/GovernancePlan.sol";

/// @title PayloadWriter
/// @notice What the scripts that write governance payloads share: where they read the governance
///         file and write, and the Safe Transaction Builder format.
abstract contract PayloadWriter is Script {
    /// @dev Overridden by tests, whose file has every value set.
    function _governanceFile() internal view virtual returns (string memory) {
        return GovernanceConfig.defaultFile();
    }

    function _outDir() internal view virtual returns (string memory);

    function _write(string memory dir, string memory name, uint256 chainId, address safe, Tx[] memory txs) internal {
        // forge-lint: disable-next-line(unsafe-cheatcode) writes the batches under out/
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

    function _one(Tx memory t) internal pure returns (Tx[] memory txs) {
        txs = new Tx[](1);
        txs[0] = t;
    }
}
