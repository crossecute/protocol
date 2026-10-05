// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {RegistrySeed, ProviderSeed} from "src/registry/ChainRegistry.sol";
import {Provenance} from "src/registry/Provenance.sol";

/// @notice A registry that is born knowing nothing, for suites that configure it as its owner.
function unseeded() pure returns (RegistrySeed memory) {
    return RegistrySeed({governorHome: "", governorHomeGrade: Provenance.Unresolved, providers: new ProviderSeed[](0)});
}
