// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

/// @notice The owner calls a signed transmitter adds to ERC-7786's `sendMessage`. Import-free so
///         the source guard can read their selectors, as it reads `sendMessage`'s from `IErc7786`.
interface ISignedOwnerCalls {
    /// @notice `payload` is `abi.encode(root, authorityCounter, BootstrapLeaf, bytes32[] proof)`.
    function bootstrap(bytes calldata payload, bytes[] calldata attributes) external payable;

    /// @notice Record `root` for `relayLeaf`. Stores no signatures: each relay supplies the
    ///         signed registration from this call's source transaction.
    function registerRoot(bytes32 root) external;
}
