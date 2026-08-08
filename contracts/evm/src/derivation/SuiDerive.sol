// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Blake2b256} from "./Blake2b256.sol";

/// @title SuiDerive
/// @notice Sui address and object-ID derivation, executable on Ethereum.
/// @dev Every constant below was read from MystenLabs/sui rather than recalled.
library SuiDerive {
    using Blake2b256 for bytes;

    /* ------------------------------- flags -------------------------------- */
    // crates/sui-types/src/crypto.rs :: SignatureScheme::flag()
    uint8 internal constant FLAG_ED25519 = 0x00;
    uint8 internal constant FLAG_SECP256K1 = 0x01;
    uint8 internal constant FLAG_SECP256R1 = 0x02;
    uint8 internal constant FLAG_MULTISIG = 0x03;
    uint8 internal constant FLAG_BLS12381 = 0x04; // not valid for a user address
    uint8 internal constant FLAG_ZKLOGIN = 0x05;
    uint8 internal constant FLAG_PASSKEY = 0x06;

    /* --------------------------- intent scopes ---------------------------- */
    // crates/shared-crypto/src/intent.rs :: HashingIntentScope
    // NOTE: these are 0xf0/0xf1, NOT 0/1. Assuming a zero-based enum here silently
    // produces well-formed but wrong object IDs.
    uint8 internal constant SCOPE_CHILD_OBJECT_ID = 0xf0;
    uint8 internal constant SCOPE_REGULAR_OBJECT_ID = 0xf1;

    error InvalidFlag();
    error LengthMismatch();

    /// @notice Sui address = blake2b256(flag ‖ pubkey).
    /// @dev crates/sui-types/src/base_types.rs :: impl From<&PublicKey> for SuiAddress
    /// @param flag One of the FLAG_* constants.
    /// @param pubkey Raw public key bytes. Ed25519 is 32; secp256k1/r1 are 33
    ///        (SEC1 compressed). Length is checked where it is fixed.
    function addressFromPubkey(uint8 flag, bytes memory pubkey)
        internal
        view
        returns (bytes32)
    {
        if (flag == FLAG_ED25519) {
            if (pubkey.length != 32) revert LengthMismatch();
        } else if (flag == FLAG_SECP256K1 || flag == FLAG_SECP256R1 || flag == FLAG_PASSKEY)
        {
            if (pubkey.length != 33) revert LengthMismatch();
        } else if (flag != FLAG_ZKLOGIN) {
            // MultiSig has its own constructor; BLS is not a valid user address.
            revert InvalidFlag();
        }
        return Blake2b256.hash(abi.encodePacked(flag, pubkey));
    }

    /// @notice MultiSig address.
    /// @dev blake2b256( 0x03 ‖ le16(threshold) ‖ (flag_i ‖ pk_i ‖ weight_i)* )
    ///      Threshold is u16 little-endian; each weight is u8. Order of the member
    ///      list is significant: it must match the on-chain MultiSigPublicKey.
    /// @param flags Per-member scheme flags.
    /// @param pubkeys Per-member raw public keys, same order as `flags`.
    /// @param weights Per-member weights, same order.
    function addressFromMultisig(
        uint16 threshold,
        uint8[] memory flags,
        bytes[] memory pubkeys,
        uint8[] memory weights
    ) internal view returns (bytes32) {
        uint256 n = flags.length;
        if (pubkeys.length != n || weights.length != n) revert LengthMismatch();

        bytes memory pre = abi.encodePacked(FLAG_MULTISIG, _le16(threshold));
        for (uint256 i; i < n; ++i) {
            pre = abi.encodePacked(pre, flags[i], pubkeys[i], weights[i]);
        }
        return Blake2b256.hash(pre);
    }

    /// @notice Object ID created by a transaction.
    /// @dev crates/sui-types/src/base_types.rs :: ObjectID::derive_id
    ///      blake2b256( 0xf1 ‖ txDigest ‖ le64(creationNum) ), truncated to 32 bytes
    ///      (already 32, so the truncation is a no-op).
    ///
    ///      This is derivable but NOT counterfactual: `txDigest` does not exist until
    ///      the transaction is built and signed, and `creationNum` depends on how many
    ///      IDs that transaction already created. Use it to VERIFY an object ID
    ///      reported back by the destination, not to predict one in advance.
    function deriveObjectId(bytes32 txDigest, uint64 creationNum)
        internal
        view
        returns (bytes32)
    {
        return Blake2b256.hash(
            abi.encodePacked(SCOPE_REGULAR_OBJECT_ID, txDigest, _le64(creationNum))
        );
    }

    /// @notice Dynamic-field / child object ID variant.
    function deriveChildObjectId(bytes32 txDigest, uint64 creationNum)
        internal
        view
        returns (bytes32)
    {
        return Blake2b256.hash(
            abi.encodePacked(SCOPE_CHILD_OBJECT_ID, txDigest, _le64(creationNum))
        );
    }

    function _le16(uint16 x) private pure returns (bytes2) {
        return bytes2(uint16((uint16(x & 0xff) << 8) | (x >> 8)));
    }

    function _le64(uint64 x) private pure returns (bytes8 r) {
        uint64 v;
        for (uint256 i; i < 8; ++i) {
            v = (v << 8) | (x & 0xff);
            x >>= 8;
        }
        r = bytes8(v);
    }
}
