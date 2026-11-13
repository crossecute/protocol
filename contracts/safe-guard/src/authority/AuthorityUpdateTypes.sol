// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice One source Safe's selected graph and linked-update position.
/// @dev authorityHash == 0 means unregistered; zero is never a valid installed graph hash.
struct AuthoritySelection {
    bytes32 updateHead;
    bytes32 authorityHash;
}

/// @notice Signed predecessor and replacement commitments, reusable on every destination.
/// @dev The surrounding SafeTx binds the source Safe, source chain and recognized guard.
///      Ordering uses previousUpdateHash, not a numeric SafeTx nonce watermark.
struct AuthorityUpdate {
    bytes32 previousUpdateHash;
    bytes32 previousAuthorityHash;
    bytes32 newAuthorityHash;
}
