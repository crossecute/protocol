// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IRefValidator
/// @notice The registry's per-chain value-range check on an address.
/// @dev ERC-7930 fixes structure, not ranges: `parseStrict` accepts 32 canonical bytes but
///      cannot reject a Starknet address above `L2_ADDRESS_UPPER_BOUND`. Set per chainKey by
///      `ChainRegistry.setValidator`.
interface IRefValidator {
    /// @param interop Canonical ERC-7930 bytes, already structurally parsed.
    /// @dev Reverts to reject. Called by `ChainRegistry.validateLocation`.
    function validateRef(bytes calldata interop) external view;
}
