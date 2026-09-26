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
        if (attributes.length == 0) return (false, "");
        bytes memory attribute = attributes[0];
        if (
            attribute.length < 4 || _selectorOf(attribute) != selector
                || (bodyLength != 0 && attribute.length - 4 != bodyLength)
        ) revert UnsupportedAttribute(attribute);
        if (attributes.length > 1) revert UnsupportedAttribute(attributes[1]);

        out = new bytes(attribute.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = attribute[i + 4];
        }
        return (true, out);
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

    /// @dev Callers check `attribute.length >= 4` first.
    function _selectorOf(bytes memory attribute) private pure returns (bytes4 selector) {
        assembly {
            selector := mload(add(attribute, 32))
        }
    }
}
