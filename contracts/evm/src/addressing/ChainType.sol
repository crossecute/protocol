// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ChainType
/// @notice The single allocation table for ERC-7930 ChainType values.
///
/// @dev WHY THIS IS ONE FILE. A ChainType is baked into every envelope and registry keys are
///      `keccak256(envelope)`, so two files each picking a provisional value is how you get a
///      silent collision that only surfaces as two chains sharing a key.
///
/// @dev ONBOARDING A CHAIN TYPE IS TWO STEPS, AND ALLOCATING HERE IS ONLY THE FIRST.
///      `Erc7930.parseStrict` reads the field as an opaque `uint16` and validates nothing
///      against this table, so a value's presence here buys collision avoidance and nothing
///      else. The profile's CANONICITY RULE must be written into `parseStrict` alongside it,
///      or two encodings of one address hash to two registry keys with no error anywhere.
///      See "Adding a chain type" in the README.
///
/// @dev ASSIGNED values come from the CASA namespace registry's CAIP-350 profiles.
///      PROVISIONAL values are local, live at or above `PROVISIONAL_FLOOR`, and face a
///      re-keying migration if CASA later publishes a different value for them. CASA
///      allocates upward from 0x0000, so 0xFF00..0xFFFF makes a collision implausible.
library ChainType {
    /* ================================ assigned ================================= */

    uint16 internal constant EIP155 = 0x0000; // eip155/caip350.md
    uint16 internal constant BIP122 = 0x0001; // bip122/caip350.md
    uint16 internal constant SOLANA = 0x0002; // solana/caip350.md
    uint16 internal constant STARKNET = 0x0003; // starknet/caip350.md

    /* =============================== provisional =============================== */

    /// @dev Anything at or above this is locally assigned and subject to re-keying.
    uint16 internal constant PROVISIONAL_FLOOR = 0xFF00;

    /// @dev Aptos-Move: 32-byte AccountAddress, SHA3-256 derivation. Movement shares
    ///      this profile and is distinguished by ChainReference, not ChainType.
    uint16 internal constant APTOS = 0xFF01;
    /// @dev Sui-Move: 32-byte address/ObjectID, BLAKE2b-256 derivation.
    uint16 internal constant SUI = 0xFF02;
    /// @dev Cosmos/CosmWasm: 32-byte canonical address (20 on forked wasmd chains).
    ///      `cosmos/` has a CAIP-2 profile only.
    uint16 internal constant COSMOS = 0xFF03;
    /// @dev NEAR: named accounts are variable-length UTF-8, implicit accounts are 32
    ///      bytes, eth-implicit are 20. `near/` has a CAIP-2 profile only.
    uint16 internal constant NEAR = 0xFF04;

    function isProvisional(uint16 chainType) internal pure returns (bool) {
        return chainType >= PROVISIONAL_FLOOR;
    }
}
