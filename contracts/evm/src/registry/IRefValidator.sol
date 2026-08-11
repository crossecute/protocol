// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IRefValidator
/// @notice The registry's per-chain validation hook.
///
/// @dev IT EXISTS BECAUSE THE ERC-7930 ENVELOPE EXPRESSES STRUCTURE, NOT VALUE RANGES.
///      `parseStrict` can tell you an address is 32 canonical bytes; it cannot tell you the
///      value is above Starknet's `L2_ADDRESS_UPPER_BOUND` and therefore names a contract
///      that can never exist.
///
/// @dev It is declared here rather than in one chain's derivation file because
///      `ChainRegistry.setValidator` wires it per chainKey (Move for AIP-40 address width,
///      Starknet for the felt bound), and every validator would otherwise import Starknet
///      just to say what shape it was.
interface IRefValidator {
    /// @param interop Canonical ERC-7930 bytes, already structurally parsed.
    /// @dev MUST revert to reject. Called on every store for the matching chainKey.
    function validateRef(bytes calldata interop) external view;
}
