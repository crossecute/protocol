// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev ABI layout of `UlnBase.UlnConfig` in LayerZero's message libraries.
struct UlnConfig {
    uint64 confirmations;
    uint8 requiredDVNCount;
    uint8 optionalDVNCount;
    uint8 optionalDVNThreshold;
    address[] requiredDVNs;
    address[] optionalDVNs;
}
