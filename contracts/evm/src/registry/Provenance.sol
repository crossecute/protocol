// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice How much this chain can actually know about an address on another one.
///
/// @dev IT GRADES A CHAIN, NOT A STORED VALUE. Where a counterpart sits is per provider and
///      lives on the hub that sends to it; how well an address on that chain can be known is
///      the same question for every provider, so `ChainRegistry.provenanceFor` answers it
///      once and every hub reads the same answer. Two hubs cannot disagree about how well
///      Starknet can be known.
///
/// @dev Ordered by increasing strength. `Derived` means this chain can recompute the
///      address from inputs in a signed transaction. `Attested` means it cannot, so the
///      value was learned over a bridge and is worth exactly that bridge's security.
///
/// @dev THERE IS NO MIDDLE GRADE, because the question has no middle. Either this chain can
///      recompute an address on that one, or it cannot and has to be told; a third value
///      would have to mean something between "arithmetic" and "somebody said so", and
///      nothing does.
///
/// @dev TRIPWIRE: THE ORDER IS THE SEMANTICS. Every check is an ordinal comparison against
///      a bar, so inserting a grade in the middle renumbers the ones above it. Both the
///      registry's `provenanceOf` and a hub's `minCounterpartProvenance` are proxy storage,
///      which outlives the bytecode that wrote it, so after a deployment that is not an
///      enum edit but a migration that silently restates every configured chain. Append, or
///      migrate deliberately.
enum Provenance {
    Unresolved,
    Attested,
    Derived
}
