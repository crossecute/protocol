// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ChainRegistry, RegistrySeed, ProviderSeed} from "src/registry/ChainRegistry.sol";
import {Status} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";

/// @notice A registry that is born knowing nothing, for suites that configure it as its owner.
function unseeded() pure returns (RegistrySeed memory) {
    return RegistrySeed({
        governorHome: "", governorHomeGrade: Provenance.Unknown, deployer: address(0), providers: new ProviderSeed[](0)
    });
}

/// @notice Records `provider` on `chainKey` as live under a test deployer, as the registry's owner
///         would. The caller must be the owner. A deployment record and a current deployer that
///         are missing are filled in.
function listLive(ChainRegistry registry, bytes32 provider, bytes32 chainKey) {
    if (registry.providerDeployment(provider).salt == bytes32(0)) {
        registry.setProviderDeployment(provider, keccak256("test salt"), keccak256("test initcode"));
    }
    if (registry.currentDeployer() == address(0)) registry.setCurrentDeployer(address(0xD1));
    registry.addProviderOnChain(chainKey, provider, registry.currentDeployer());
    if (registry.statusOf(chainKey, provider) != Status.Live) registry.markLive(chainKey, provider);
}
