// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Decides which accounts a transceiver lets bootstrap, where its owner has named one.
interface IBootstrapAllowlist {
    /// @param account The transmitter bootstrapping: `msg.sender` of `bootstrap`.
    function isAllowed(address account) external view returns (bool);
}
