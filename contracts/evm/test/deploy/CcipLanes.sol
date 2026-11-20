// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ChainConfig, ChainEntry, Derivation} from "script/deploy/ChainConfig.sol";
import {MockCcipRamp, MockCcipRouter} from "test/protocols/ccip/MockCcipRouter.sol";

/// @notice Registers on `router` an OnRamp and OffRamp reporting `version` for every parity chain
///         the provider reaches other than the current one, the lanes `CcipPreflight` resolves.
function installCcipLanes(MockCcipRouter router, string memory version) {
    string memory dir = ChainConfig.defaultDir();
    ChainEntry[] memory cs = ChainConfig.chains(dir);
    router.clearOffRamps();
    for (uint256 i; i < cs.length; ++i) {
        uint256 id = ChainConfig.providerId(dir, cs, "ccip", cs[i]);
        if (cs[i].chainId == block.chainid || cs[i].derivation != Derivation.Parity || id == 0) continue;
        // forge-lint: disable-next-line(unsafe-typecast) ccip.toml's id_bits is 64
        router.setLane(
            uint64(id),
            address(new MockCcipRamp(string.concat("OnRamp ", version))),
            address(new MockCcipRamp(string.concat("OffRamp ", version)))
        );
    }
}
