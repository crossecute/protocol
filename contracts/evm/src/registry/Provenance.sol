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
/// @dev `Committed` HAS NO PRODUCER. Nothing grades a reference at it, and the value
///      exists only as a CAP: several chains are configured at it through
///      `setMaxProvenance` (Aptos, Starknet), where its job is to make `Derived`
///      unrepresentable. Removing it would renumber `Derived` and silently loosen every
///      one of those caps. A reference reported by a destination lands at `Attested`, and
///      a reader wanting better must use a locally derived path.
enum Provenance {
    Unresolved,
    Attested,
    Committed,
    Derived
}
