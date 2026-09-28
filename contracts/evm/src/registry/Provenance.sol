// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice How much this chain can know about an address on another one.
///
/// @dev Grades a chain, not a stored value: every provider's hub reads the same answer from
///      `ChainRegistry.provenanceFor`, so two hubs cannot disagree about one chain.
///
/// @dev Ordered by strength. `Derived`: this chain can recompute the address from inputs in a
///      signed transaction. `Attested`: it cannot, so the value came over a bridge and is
///      worth that bridge's security.
///
/// @dev Checks are ordinal comparisons against a bar, and the registry's `provenanceOf` and a
///      hub's `minCounterpartProvenance` persist in proxy storage. Inserting a grade renumbers
///      every stored value above it after deployment: append, or migrate.
enum Provenance {
    Unresolved,
    Attested,
    Derived
}
