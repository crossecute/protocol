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

/// @notice The Safe 1.5.0 factory inputs that prove a Safe's creation owners and threshold.
/// @dev The factory and proxy initcode are compiled-in pins (SafeDeployment.sol), so neither is
///      carried. initializer is setup(...): owners and threshold are read from it.
struct SafeCreationProof {
    address singleton;
    bytes initializer;
    uint256 saltNonce;
}
