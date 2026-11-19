// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Owner kinds in a `SafeAuthorityRecord`. Any other value is rejected.
uint8 constant OWNER_EOA = 0;
uint8 constant OWNER_SAFE = 1;

/// @notice One immediate owner of a Safe. A nested Safe owner refers to the record with its
///         address, never to a position in the record list.
struct SafeOwner {
    address owner;
    uint8 kind;
}

/// @notice One Safe's authority: its threshold and its owners in `getOwners()` order.
struct SafeAuthorityRecord {
    address safe;
    uint256 threshold;
    SafeOwner[] owners;
}
