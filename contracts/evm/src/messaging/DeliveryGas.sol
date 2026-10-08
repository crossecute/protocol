// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The destination gas a message is sent with when its attributes name none, by what
///         it does on arrival.
/// @dev Measured cold on Forge's EVM with every binding's fixture (deploy/CHECKS.md §4): a
///      bootstrap that creates an account 590k to 650k, a report arriving home up to 135k. A
///      bootstrap on a reporting chain also pays for the report's send. EraVM is not measured.
library DeliveryGas {
    uint256 internal constant BOOTSTRAP = 1_000_000;
    uint256 internal constant REPORT = 250_000;
    uint256 internal constant PAYLOAD = 200_000;
}
