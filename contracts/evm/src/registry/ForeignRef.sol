// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice How much this chain actually knows about a stored value.
/// @dev Ordered by increasing strength; upgrades allowed, downgrades revert. This is
///      the field a payload reviewer should read. `Attested` is worth exactly the
///      security of the bridge that asserted it. `Derived` was recomputed here.
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

/// @notice A resolved foreign reference.
/// @dev `id` is keccak256 of the canonical ERC-7930 envelope and is the only key.
///      Arbitrary-length identifiers are handled by the envelope itself rather than by
///      a form discriminant, so NEAR named accounts, Cardano addresses, TON
///      workchain+account_id, Move type tags, and 20-byte EVM addresses all take the
///      same shape.
struct ForeignRef {
    bytes32 id;
    bytes32 chainKey;
    Provenance provenance;
    /// keccak256 of the attached MoveQualifier, or zero when none. Kept OUTSIDE `id`
    /// so that `id` stays a pure function of the ERC-7930 envelope: a call target and
    /// the address it lives at must remain the same registry key.
    bytes32 qualifierHash;
    /// Canonical ERC-7930 bytes, re-encoded from parsed parts on store.
    bytes interop;
}

/// @notice Source-side callback for identifiers this chain cannot compute.
///
/// @dev TRANSCEIVER LOCATIONS ONLY. An account's receiver address used to come through here
///      too; it is a fact about that account rather than about a chain, and only the
///      transmitter that addresses it ever reads it, so the hub now writes it straight there
///      (`TransmitterBase.onDestinationReceiverReported`). What is left is the counterpart
///      directory, which is chain-scoped and is what a registry is for.
///
/// @dev NO REQUEST ID, AND NOTHING TO REGISTER IN ADVANCE. The caller is authenticated as a
///      registered local transceiver, which is what names the message provider, and the slot
///      is WRITE-ONCE, so a replayed report cannot repoint a counterpart already on record.
interface IForeignRefReceiver {
    /// @param slot          Storage key for this reference: the transceiver id.
    /// @param interop       Canonical ERC-7930 bytes reported by the destination.
    /// @param qualifierData abi-encoded `Move.MoveQualifier` as reported by the
    ///                      destination, or empty for chains that have no qualified
    ///                      names. This travels over the wire ALONGSIDE the address
    ///                      because a Move call target is `address::module::function`
    ///                      and the address alone does not identify it.
    function onForeignRefResolved(
        bytes32 slot,
        bytes calldata interop,
        bytes calldata qualifierData
    ) external;
}
