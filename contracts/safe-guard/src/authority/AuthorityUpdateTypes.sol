// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice One source Safe's selected graph and linked-update position.
/// @dev authorityHash == 0 means unregistered; zero is never a valid installed graph hash.
struct AuthoritySelection {
    bytes32 updateHead;
    bytes32 authorityHash;
}

/// @notice What an ownership change or selectAuthority signs, reusable on every destination.
/// @dev The surrounding SafeTx binds the source Safe, source chain and recognized guard.
///      previousUpdateHash is the predecessor's SafeTx hash, which already commits to that
///      update's graph hash, so the previous graph hash is not repeated here.
struct AuthorityUpdate {
    bytes32 previousUpdateHash;
    bytes32 newAuthorityHash;
}

