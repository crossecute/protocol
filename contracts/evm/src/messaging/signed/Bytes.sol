// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Copies out of `bytes memory` without `mcopy`, which Paris lacks.
library Bytes {
    error OutOfBounds();
    error WrongSelector(bytes4 expected);

    /// @notice Copy `length` bytes from `start` into a new array, reverting if the range is invalid.
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

    /// @notice The calldata after `selector`, reverting if `data` does not start with it.
    function arguments(bytes memory data, bytes4 selector) internal pure returns (bytes memory) {
        // forge-lint: disable-next-line(unsafe-typecast) the first four bytes, after the length check
        if (data.length < 4 || bytes4(data) != selector) revert WrongSelector(selector);
        return slice(data, 4, data.length - 4);
    }
}
