// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTx} from "./ICrossecuteGuard.sol";

/// @notice Safe 1.5.0's EIP-712 hashes, computed without calling the Safe.
/// @dev Mirrors `Safe.getTransactionHash`, `Safe.domainSeparator` and `SignMessageLib.getMessageHash`
///      at v1.5.0. Uses no `mcopy`, so it compiles for Paris.
library SafeHashes {
    /// @dev Safe's `DOMAIN_SEPARATOR_TYPEHASH`,
    ///      `keccak256("EIP712Domain(uint256 chainId,address verifyingContract)")`.
    bytes32 internal constant DOMAIN_SEPARATOR_TYPEHASH =
        0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;

    /// @dev Safe's `SAFE_TX_TYPEHASH`, the EIP-712 type hash of `SafeTx`.
    bytes32 internal constant SAFE_TX_TYPEHASH = 0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8;

    /// @dev Safe's `SAFE_MSG_TYPEHASH`, `keccak256("SafeMessage(bytes message)")`.
    bytes32 internal constant SAFE_MSG_TYPEHASH = 0x60b3cbf8b4a223d68d641b3b6ddf9a298e7f33710cf3d3a9d1146b5a6150fbca;

    /// @notice The hash `safe` on chain `chainId` returns from `getTransactionHash` for `safeTx`.
    function transactionHash(SafeTx memory safeTx, address safe, uint256 chainId)
        internal
        pure
        returns (bytes32 txHash)
    {
        bytes32 domain = domainSeparator(safe, chainId);
        assembly ("memory-safe") {
            // Scratch space past the free memory pointer; nothing here outlives the block.
            let ptr := mload(0x40)
            // `safeTx` is a pointer to ten words in field order; word 2 points to `data`.
            let data := mload(add(safeTx, 0x40))
            // EIP-712 struct encoding: the type hash, then each field as one word.
            mstore(ptr, SAFE_TX_TYPEHASH)
            // to
            mstore(add(ptr, 0x20), mload(safeTx))
            // value
            mstore(add(ptr, 0x40), mload(add(safeTx, 0x20)))
            // data, encoded as the keccak256 of its bytes (length word skipped)
            mstore(add(ptr, 0x60), keccak256(add(data, 0x20), mload(data)))
            // operation
            mstore(add(ptr, 0x80), mload(add(safeTx, 0x60)))
            // safeTxGas
            mstore(add(ptr, 0xa0), mload(add(safeTx, 0x80)))
            // baseGas
            mstore(add(ptr, 0xc0), mload(add(safeTx, 0xa0)))
            // gasPrice
            mstore(add(ptr, 0xe0), mload(add(safeTx, 0xc0)))
            // gasToken
            mstore(add(ptr, 0x100), mload(add(safeTx, 0xe0)))
            // refundReceiver
            mstore(add(ptr, 0x120), mload(add(safeTx, 0x100)))
            // nonce
            mstore(add(ptr, 0x140), mload(add(safeTx, 0x120)))
            // hashStruct(safeTx) over the 11 words above
            let structHash := keccak256(ptr, 0x160)
            // 0x1901 right-aligned in the first word, so it occupies bytes 30 and 31
            mstore(ptr, 0x1901)
            // domain separator follows the prefix at byte 32
            mstore(add(ptr, 0x20), domain)
            // struct hash at byte 64
            mstore(add(ptr, 0x40), structHash)
            // keccak256(0x1901 || domain || structHash): 2 + 32 + 32 = 66 bytes from byte 30
            txHash := keccak256(add(ptr, 0x1e), 0x42)
        }
    }

    /// @notice The hash `SignMessageLib.signMessage(message)` writes into `signedMessages` when `safe`
    ///         on chain `chainId` delegatecalls it, and that the Safe's fallback handler returns
    ///         from `getMessageHashForSafe`.
    function messageHash(bytes memory message, address safe, uint256 chainId) internal pure returns (bytes32) {
        bytes32 safeMessageHash = keccak256(abi.encode(SAFE_MSG_TYPEHASH, keccak256(message)));
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator(safe, chainId), safeMessageHash));
    }

    /// @notice The domain separator `safe` on chain `chainId` returns from `domainSeparator`.
    function domainSeparator(address safe, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_SEPARATOR_TYPEHASH, chainId, safe));
    }
}
