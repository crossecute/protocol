// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The destination gas a message is sent with when its attributes name none, by what
///         it does on arrival.
/// @dev Measured cold on Forge's EVM with every binding's fixture (deploy/CHECKS.md §4), and
///      held at least 10% above that by `ProviderDeliveryGasSpec`: a bootstrap that creates an
///      account 624k to 678k, a report arriving home up to 128k. A bootstrap on a reporting
///      chain also pays for the report's send. On EraVM a bootstrap's
///      execution is about 385k to 389k; its pubdata is not measured. A gas attribute replaces
///      these with no floor: a delivery short of gas reverts and is retried with more
///      (provider-spec R1.5).
library DeliveryGas {
    uint256 internal constant BOOTSTRAP = 1_000_000;
    uint256 internal constant REPORT = 250_000;
    uint256 internal constant PAYLOAD = 200_000;
}
