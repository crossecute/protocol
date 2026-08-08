// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice One call in a payload.
///
/// @dev THIS IS THE ERC-7579 `Execution` TUPLE, also used by ERC-7821. The reason to
///      prefer it over a bespoke struct is not the bytes saved: it is that payload
///      builders which already speak modular-account formats work without custom code.
///
/// @dev TARGET AND VALUE ARE PART OF THE CALL, not context around it, so an approval over
///      an array covers who is called and how much they receive rather than only what is
///      sent. A payload cannot be redirected or re-priced at execution time.
struct Call {
    address target;
    uint256 value;
    bytes data;
}

/// @title Calls
/// @notice Conversion between the typed `Call` and the canonical opaque element.
///
/// @dev THE TWO FORMS MUST HASH IDENTICALLY, and that is this library's whole job. A
///      commitment is defined over opaque `bytes` elements so the layer stays VM-agnostic
///      (see `Commitment`), while an EVM caller wants to hand over typed calls. Both are
///      accepted, and `encode` is exactly the byte string whose keccak256 the opaque path
///      would produce, so the same logical payload commits to the same hash either way,
///      and a payload approved in one form can be delivered in the other.
library Calls {
    /// @notice The canonical opaque element for a typed call.
    ///
    /// @dev IT ENCODES THE FIELDS, NOT THE STRUCT, and the difference is not cosmetic.
    ///      `abi.encode(someStruct)` prepends an offset word, because a struct with a
    ///      dynamic member encodes as a dynamic tuple, so `abi.encode(c)` and
    ///      `abi.encode(c.target, c.value, c.data)` are different byte strings and hash to
    ///      different values. The second is the one that matches the opaque form, and
    ///      therefore the only one that can be used here.
    function encode(Call memory c) internal pure returns (bytes memory) {
        return abi.encode(c.target, c.value, c.data);
    }

    /// @notice The element hash, without materializing the element.
    /// @dev Equals `keccak256(encode(c))` by construction. Kept separate so the hashing
    ///      path does not allocate a copy of every call's data just to hash it.
    function hash(Call memory c) internal pure returns (bytes32) {
        return keccak256(abi.encode(c.target, c.value, c.data));
    }

    /// @notice Split a canonical opaque element back into a typed call.
    /// @dev Reverts if the element is not `abi.encode(address, uint256, bytes)`, which is
    ///      the correct outcome on an EVM destination, where an element that does not
    ///      decode is one this receiver cannot execute.
    function decode(bytes memory element) internal pure returns (Call memory c) {
        (c.target, c.value, c.data) = abi.decode(element, (address, uint256, bytes));
    }

    function encodeAll(Call[] memory calls) internal pure returns (bytes[] memory out) {
        out = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            out[i] = encode(calls[i]);
        }
    }

    function decodeAll(bytes[] memory elements) internal pure returns (Call[] memory out) {
        out = new Call[](elements.length);
        for (uint256 i; i < elements.length; ++i) {
            out[i] = decode(elements[i]);
        }
    }
}
