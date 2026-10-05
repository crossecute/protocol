// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice How much this chain can know about an address on another one.
///
/// @dev Grades a chain, not a stored value: every provider's transceiver reads the same answer
///      from `ChainRegistry.provenanceFor`, so two transceivers cannot disagree about one chain.
///
/// @dev Ordered by strength. `Derived`: this chain can recompute the address from inputs in a
///      signed transaction, because both chains' transceivers were deployed through
///      `CrossProxyDeployer`, which Arachnid's factory puts at one address. `Attested`: it cannot, so the value came over a bridge and is
///      worth that bridge's security. A chain without Arachnid's factory shares no address with
///      any other, so it is `Attested` in every registry and grades every other chain
///      `Attested` in its own (#33).
///
/// @dev Checks are ordinal comparisons against a bar, and the registry's grades and a
///      transceiver's `minCounterpartProvenance` persist in storage. Inserting a grade
///      renumbers every stored value above it after deployment: append, or migrate.
enum Provenance {
    Unresolved,
    Attested,
    Derived
}
