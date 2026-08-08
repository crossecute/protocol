// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IRefValidator
/// @notice The registry's per-chain validation hook.
///
/// @dev EXTRACTED FROM `StarknetDerive`, WHERE IT DID NOT BELONG. This is the generic
///      extension point `ChainRegistry.setValidator` wires per chainKey (Move uses it
///      for AIP-40 address width, Starknet for the felt bound), so declaring it inside
///      one chain's derivation file meant every other chain's validator had to import
///      Starknet to say what shape it was.
///
///      It exists because the ERC-7930 envelope expresses STRUCTURE, not value ranges.
///      `parseStrict` can tell you an address is 32 canonical bytes; it cannot tell you
///      the value is above Starknet's `L2_ADDRESS_UPPER_BOUND` and therefore names a
///      contract that can never exist.
interface IRefValidator {
    /// @param interop Canonical ERC-7930 bytes, already structurally parsed.
    /// @dev MUST revert to reject. Called on every store for the matching chainKey.
    function validateRef(bytes calldata interop) external view;
}
