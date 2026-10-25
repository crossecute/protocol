// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Parsing for the single selector-prefixed attribute each native binding accepts.
///         ERC-7786 requires a gateway to refuse any attribute it does not support.
/// @dev `attributes[0]` is validated in full (selector, length, and for `uintValue` the bound)
///      before a second attribute is refused, so a malformed first attribute is the one
///      reported rather than a well-formed extra.
library ProviderAttribute {
    error UnsupportedAttribute(bytes attribute);

    /// @notice The bytes after `selector` in the single attribute, or `present == false` when
    ///         none was given.
    /// @param bodyLength The exact body length required; zero accepts any length.
    function body(bytes[] memory attributes, bytes4 selector, uint256 bodyLength)
        internal
        pure
        returns (bool present, bytes memory out)
    {
        // forge-lint: disable-next-line(boolean-cst) the `present` flag
        if (attributes.length == 0) return (false, "");
        bytes memory attribute = attributes[0];
        if (
            attribute.length < 4 || _selectorOf(attribute) != selector
                || (bodyLength != 0 && attribute.length - 4 != bodyLength)
        ) revert UnsupportedAttribute(attribute);
        if (attributes.length > 1) revert UnsupportedAttribute(attributes[1]);

        // forge-lint: disable-next-line(boolean-cst) the `present` flag
        return (true, _bodyOf(attribute));
    }

    /// @notice `body`, for a binding that accepts several attributes together: the bytes after
    ///         `selector` in the attribute it leads, or `present == false` when none does.
    /// @dev Every attribute is checked, in order, before any is read: each must be led by one of
    ///      `supported` and none may appear twice, so a send is refused on the same input
    ///      whichever attribute its caller asks for.
    function bodyAmong(bytes[] memory attributes, bytes4 selector, bytes4[] memory supported)
        internal
        pure
        returns (bool present, bytes memory out)
    {
        for (uint256 i; i < attributes.length; ++i) {
            bytes memory attribute = attributes[i];
            if (attribute.length < 4 || !_contains(supported, _selectorOf(attribute))) {
                revert UnsupportedAttribute(attribute);
            }
            for (uint256 j; j < i; ++j) {
                if (_selectorOf(attributes[j]) == _selectorOf(attribute)) revert UnsupportedAttribute(attribute);
            }
        }
        for (uint256 i; i < attributes.length; ++i) {
            // forge-lint: disable-next-line(boolean-cst) the `present` flag
            if (_selectorOf(attributes[i]) == selector) return (true, _bodyOf(attributes[i]));
        }
    }

    /// @notice The `uint256` in a single `abi.encodePacked(selector, abi.encode(value))`
    ///         attribute, at most `max`, or `defaultValue` when none was given.
    function uintValue(bytes[] memory attributes, bytes4 selector, uint256 max, uint256 defaultValue)
        internal
        pure
        returns (uint256 value)
    {
        if (attributes.length == 0) return defaultValue;
        bytes memory attribute = attributes[0];
        if (attribute.length != 36 || _selectorOf(attribute) != selector) revert UnsupportedAttribute(attribute);
        assembly {
            value := mload(add(attribute, 36))
        }
        if (value > max) revert UnsupportedAttribute(attribute);
        if (attributes.length > 1) revert UnsupportedAttribute(attributes[1]);
    }

    /// @notice For a binding that supports no attribute: the first given is refused.
    function none(bytes[] memory attributes) internal pure {
        if (attributes.length != 0) revert UnsupportedAttribute(attributes[0]);
    }

    /// @dev Callers check `attribute.length >= 4` first.
    function _bodyOf(bytes memory attribute) private pure returns (bytes memory out) {
        // forge-lint: disable-next-line(calls-loop) allocation, not a call
        out = new bytes(attribute.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = attribute[i + 4];
        }
    }

    function _contains(bytes4[] memory set, bytes4 selector) private pure returns (bool) {
        for (uint256 i; i < set.length; ++i) {
            if (set[i] == selector) return true;
        }
        return false;
    }

    /// @dev Callers check `attribute.length >= 4` first.
    function _selectorOf(bytes memory attribute) private pure returns (bytes4 selector) {
        assembly {
            selector := mload(add(attribute, 32))
        }
    }
}
