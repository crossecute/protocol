// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/// @dev Runs several calls inside one call, so they share one transaction's transient storage.
///      Forge clears transient storage between a test's top-level calls.
contract Batch {
    struct Call {
        address target;
        bytes data;
        bool allowFailure;
    }

    function run(Call[] calldata calls) external returns (bytes[] memory results) {
        results = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; ++i) {
            (bool success, bytes memory result) = calls[i].target.call(calls[i].data);
            if (!success && !calls[i].allowFailure) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
            results[i] = result;
        }
    }
}
