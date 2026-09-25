// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";

/// @notice The one attribute every LayerZero binding accepts: execution options, as
///         `abi.encodePacked(OPTIONS_ATTRIBUTE, rawOptionsBytes)`.
library LzMessage {
    bytes4 internal constant OPTIONS_ATTRIBUTE = bytes4(keccak256("crossecute.lz.options"));

    /// @dev Empty options is a valid default (LayerZero's executor applies its own gas limit),
    ///      not a missing one.
    function options(bytes[] memory attributes) internal pure returns (bytes memory out) {
        (, out) = ProviderAttribute.body(attributes, OPTIONS_ATTRIBUTE, 0);
    }
}
