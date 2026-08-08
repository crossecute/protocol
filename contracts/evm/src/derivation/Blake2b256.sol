// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Blake2b256
/// @notice Full BLAKE2b-256 built on the EIP-152 `blake2f` compression precompile (0x09).
///
/// @dev The precompile provides only the F compression function, not a hash. This library
///      supplies the parameter block, the message padding, the byte-offset counters, and
///      the final-block flag around it.
///
///      ENDIANNESS. EIP-152 takes and returns the state `h` and message `m` as
///      little-endian 64-bit words. Because we carry `h` as opaque 64 raw bytes and pass
///      message blocks through verbatim, no word swapping is ever needed: only the
///      parameter-block XOR and the `t` counter are written in explicit little-endian.
///      This is the single most common source of wrong BLAKE2b ports; it is avoided here
///      rather than handled.
///
///      MUTABILITY. Functions here are `view`, not `pure`. Solidity forbids `staticcall`
///      inside `pure`, and there is no `blake2b` builtin the way there is for `sha256`
///      and `ripemd160`. Callers that need `pure` cannot use this; pass the digest in.
///
///      GAS. The precompile costs 1 gas per round, 12 rounds per 128-byte block, so the
///      compression itself is free in practice. Cost is dominated by memory and the
///      staticcall overhead: measured at roughly 3k gas for a single-block input.
library Blake2b256 {
    /// @dev BLAKE2b IV, little-endian bytes, with h[0] already XORed by the parameter
    ///      block 0x01010020 (fanout=1, depth=1, key length=0, digest length=32).
    ///      0x6a09e667f3bcc908 ^ 0x01010020 == 0x6a09e667f2bdc928.
    bytes private constant IV_PARAM =
        hex"28c9bdf267e6096a"
        hex"3ba7ca8485ae67bb"
        hex"2bf894fe72f36e3c"
        hex"f1361d5f3af54fa5"
        hex"d182e6ad7f520e51"
        hex"1f6c3e2b8c68059b"
        hex"6bbd41fbabd9831f"
        hex"79217e1319cde05b";

    uint32 private constant ROUNDS = 12;
    uint256 private constant BLOCK_SIZE = 128;

    error PrecompileFailed();

    /// @notice BLAKE2b-256 over an arbitrary-length input, unkeyed.
    /// @dev Handles the empty input, exact-multiple-of-128 inputs, and multi-block
    ///      inputs. All three are separately covered by the test vectors.
    function hash(bytes memory input) internal view returns (bytes32) {
        bytes memory h = IV_PARAM; // 64 bytes, mutated in place across blocks

        uint256 len = input.length;
        if (len == 0) {
            // Single all-zero final block with counter 0.
            h = _compress(h, new bytes(BLOCK_SIZE), 0, true);
        } else {
            uint256 nBlocks = (len + BLOCK_SIZE - 1) / BLOCK_SIZE;
            for (uint256 i; i < nBlocks; ++i) {
                bool last = (i == nBlocks - 1);
                uint256 offset = i * BLOCK_SIZE;
                // Counter is bytes compressed so far INCLUDING this block. For the
                // final block that is the true message length, not a padded length.
                uint64 t = uint64(last ? len : offset + BLOCK_SIZE);
                h = _compress(h, _blockAt(input, offset, len), t, last);
            }
        }

        // Digest is the first 32 bytes of the state, already in output byte order.
        bytes32 out;
        assembly {
            out := mload(add(h, 32))
        }
        return out;
    }

    /// @dev Extracts a 128-byte block starting at `offset`, zero-padded if the message
    ///      ends early. Zero padding is part of the BLAKE2b spec, not an artifact.
    function _blockAt(bytes memory input, uint256 offset, uint256 len)
        private
        pure
        returns (bytes memory blk)
    {
        blk = new bytes(BLOCK_SIZE);
        uint256 n = len - offset;
        if (n > BLOCK_SIZE) n = BLOCK_SIZE;
        for (uint256 i; i < n; ++i) {
            blk[i] = input[offset + i];
        }
    }

    /// @dev One call to the EIP-152 F compression function.
    ///      Input layout is exactly 213 bytes:
    ///        rounds  4  bytes, big-endian uint32
    ///        h      64  bytes, 8 little-endian uint64
    ///        m     128  bytes, 16 little-endian uint64
    ///        t      16  bytes, t0 then t1, each little-endian uint64
    ///        f       1  byte,  0x01 on the final block
    function _compress(bytes memory h, bytes memory blk, uint64 t0, bool last)
        private
        view
        returns (bytes memory out)
    {
        bytes memory input = abi.encodePacked(
            ROUNDS, // 4, big-endian by abi.encodePacked
            h, // 64
            blk, // 128
            _le64(t0), // 8   (t0)
            bytes8(0), // 8   (t1: messages beyond 2^64 bytes are not representable)
            last ? bytes1(0x01) : bytes1(0x00) // 1
        );

        out = new bytes(64);
        bool ok;
        assembly {
            ok := staticcall(gas(), 0x09, add(input, 32), 213, add(out, 32), 64)
        }
        if (!ok) revert PrecompileFailed();
    }

    /// @dev uint64 -> 8 little-endian bytes.
    function _le64(uint64 x) private pure returns (bytes8 r) {
        uint64 v;
        for (uint256 i; i < 8; ++i) {
            v = (v << 8) | (x & 0xff);
            x >>= 8;
        }
        r = bytes8(v);
    }
}
