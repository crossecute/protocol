// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Decides which conduits a transceiver lets bootstrap, where its owner has named one.
interface IBootstrapAllowlist {
    /// @param conduit The transmitter bootstrapping: `msg.sender` of `bootstrap`.
    function isAllowed(address conduit) external view returns (bool);
}
