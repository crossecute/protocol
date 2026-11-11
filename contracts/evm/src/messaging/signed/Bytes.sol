// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Copies out of `bytes memory` without `mcopy`, which Paris lacks.
library Bytes {
    error OutOfBounds();
    error WrongSelector(bytes4 expected);

    /// @notice Copy `length` bytes starting at `start` into a new byte array, reverting if the
    ///         range is invalid.
    /// @dev Signature payloads and call arguments need independent slices. Copy without `MCOPY`
    ///      so the helper works on the protocol's Paris EVM target.
    function slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory out) {
        if (start > data.length || length > data.length - start) revert OutOfBounds();
        out = new bytes(length);
        assembly ("memory-safe") {
            // Whole words: `out` is allocated in whole words, and a read past `data` is discarded
            // by `out`'s length.
            let from := add(add(data, 0x20), start)
            let to := add(out, 0x20)
            for { let i := 0 } lt(i, length) { i := add(i, 0x20) } { mstore(add(to, i), mload(add(from, i))) }
        }
    }

    /// @notice Check the function selector and return the remaining bytes of `data`.
    /// @dev Signed-call decoders must confirm which function was authorized before interpreting
    ///      its arguments; stripping any four bytes would allow the wrong call type.
    function arguments(bytes memory data, bytes4 selector) internal pure returns (bytes memory) {
        // forge-lint: disable-next-line(unsafe-typecast) the first four bytes, after the length check
        if (data.length < 4 || bytes4(data) != selector) revert WrongSelector(selector);
        return slice(data, 4, data.length - 4);
    }
}
