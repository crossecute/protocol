// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ChainConfig, ChainEntry, Derivation} from "script/deploy/ChainConfig.sol";
import {MockCcipRamp, MockCcipRouter} from "test/protocols/ccip/MockCcipRouter.sol";

/// @notice Registers on `router` an OnRamp and an OffRamp reporting `version` for every parity chain
///         other than the current one, in each direction `ccip.toml` carries: the lanes
///         `CcipPreflight` resolves.
function installCcipLanes(MockCcipRouter router, string memory version) {
    string memory dir = ChainConfig.defaultDir();
    ChainEntry[] memory cs = ChainConfig.chains(dir);
    ChainEntry memory local = ChainConfig.chainWithId(cs, block.chainid);
    router.clearOffRamps();
    for (uint256 i; i < cs.length; ++i) {
        if (cs[i].chainId == block.chainid || cs[i].derivation != Derivation.Parity) continue;
        uint256 outbound = ChainConfig.routeId(dir, cs, "ccip", local, cs[i]);
        uint256 inbound = ChainConfig.routeId(dir, cs, "ccip", cs[i], local);
        if (outbound == 0 && inbound == 0) continue;
        address onRamp = outbound == 0 ? address(0) : address(new MockCcipRamp(string.concat("OnRamp ", version)));
        address offRamp = inbound == 0 ? address(0) : address(new MockCcipRamp(string.concat("OffRamp ", version)));
        // forge-lint: disable-next-line(unsafe-typecast) ccip.toml's id_bits is 64
        router.setLane(uint64(ChainConfig.providerId(dir, cs, "ccip", cs[i])), onRamp, offRamp);
    }
}
