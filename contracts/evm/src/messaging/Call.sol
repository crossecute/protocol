// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice One call in a payload.
/// @dev The ERC-7579 `Execution` tuple, also used by ERC-7821, so existing payload builders
///      work unchanged. Target and value are in the approved array, so a payload cannot be
///      redirected or re-priced at execution.
struct Call {
    address target;
    uint256 value;
    bytes data;
}

/// @title Calls
/// @notice Conversion between the typed `Call` and the canonical opaque element.
/// @dev The two forms must hash identically, so an approval made in one form can be
///      discharged in the other.
library Calls {
    /// @notice The canonical opaque element for a typed call.
    /// @dev Encodes the fields, not the struct: `abi.encode(c)` prepends an offset word for the
    ///      dynamic tuple and would hash differently.
    function encode(Call memory c) internal pure returns (bytes memory) {
        return abi.encode(c.target, c.value, c.data);
    }

    /// @notice The element hash. Equals `keccak256(encode(c))`.
    function hash(Call memory c) internal pure returns (bytes32) {
        return keccak256(abi.encode(c.target, c.value, c.data));
    }

    /// @notice Split a canonical opaque element back into a typed call. Reverts if it is not
    ///         `abi.encode(address, uint256, bytes)`.
    function decode(bytes memory element) internal pure returns (Call memory c) {
        (c.target, c.value, c.data) = abi.decode(element, (address, uint256, bytes));
    }

    function encodeAll(Call[] memory calls) internal pure returns (bytes[] memory out) {
        out = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            out[i] = encode(calls[i]);
        }
    }
}
