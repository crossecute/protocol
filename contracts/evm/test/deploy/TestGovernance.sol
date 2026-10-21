// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VmSafe} from "forge-std/Vm.sol";
import {VM} from "script/deploy/CrossProxyDeploy.sol";
import {ChainConfig} from "script/deploy/ChainConfig.sol";
import {Governance, GovernanceConfig} from "script/deploy/ChainDeploy.sol";

/// @notice `deploy/governance.toml` leaves its addresses unset, so the deploy tests read a copy
///         with every value set.
function testGovernanceFile() view returns (string memory) {
    return string.concat(VM.projectRoot(), "/test/deploy/config/governance.toml");
}

function testGovernance() view returns (Governance memory) {
    return GovernanceConfig.read(testGovernanceFile(), ChainConfig.chains(ChainConfig.defaultDir()));
}

/// @notice `forge coverage` builds unoptimized, so `CrossProxy`'s initcode hash is not the one
///         the governance file records, and a deployment from that file fails R8.4 there.
function skipUnderCoverage() {
    if (VM.isContext(VmSafe.ForgeContext.Coverage)) VM.skip(true);
}
