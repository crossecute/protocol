// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICrossecuteGuard} from "./ICrossecuteGuard.sol";

/// @notice Safe 1.5.0's `getTransactionHash`, computed from a `SafeTx` without calling the Safe.
/// @dev Mirrors `Safe.getTransactionHash` and `Safe.domainSeparator` at v1.5.0. Uses no `mcopy`, so
///      it compiles for Paris.
library SafeTxHash {
    /// @dev Safe's `DOMAIN_SEPARATOR_TYPEHASH`,
    ///      `keccak256("EIP712Domain(uint256 chainId,address verifyingContract)")`.
    bytes32 internal constant DOMAIN_SEPARATOR_TYPEHASH =
        0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;

    /// @dev Safe's `SAFE_TX_TYPEHASH`, the EIP-712 type hash of `SafeTx`.
    bytes32 internal constant SAFE_TX_TYPEHASH = 0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8;

    /// @notice The hash `safe` on chain `chainId` returns from `getTransactionHash` for `safeTx`.
    function hash(ICrossecuteGuard.SafeTx memory safeTx, address safe, uint256 chainId)
        internal
        pure
        returns (bytes32 txHash)
    {
        bytes32 domain = domainSeparator(safe, chainId);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            let data := mload(add(safeTx, 0x40))
            mstore(ptr, SAFE_TX_TYPEHASH)
            mstore(add(ptr, 0x20), mload(safeTx))
            mstore(add(ptr, 0x40), mload(add(safeTx, 0x20)))
            mstore(add(ptr, 0x60), keccak256(add(data, 0x20), mload(data)))
            mstore(add(ptr, 0x80), mload(add(safeTx, 0x60)))
            mstore(add(ptr, 0xa0), mload(add(safeTx, 0x80)))
            mstore(add(ptr, 0xc0), mload(add(safeTx, 0xa0)))
            mstore(add(ptr, 0xe0), mload(add(safeTx, 0xc0)))
            mstore(add(ptr, 0x100), mload(add(safeTx, 0xe0)))
            mstore(add(ptr, 0x120), mload(add(safeTx, 0x100)))
            mstore(add(ptr, 0x140), mload(add(safeTx, 0x120)))
            let structHash := keccak256(ptr, 0x160)
            mstore(ptr, 0x1901)
            mstore(add(ptr, 0x20), domain)
            mstore(add(ptr, 0x40), structHash)
            txHash := keccak256(add(ptr, 0x1e), 0x42)
        }
    }

    /// @notice The domain separator `safe` on chain `chainId` returns from `domainSeparator`.
    function domainSeparator(address safe, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_SEPARATOR_TYPEHASH, chainId, safe));
    }
}
