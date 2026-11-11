// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTxEvidence, ExecutionLeaf} from "../signed/types/SignedDispatchTypes.sol";

/// @notice A transmitter in signed mode: the owner calls, and the permissionless relay.
interface ISignedTransmitter {
    error RootAlreadyRegistered(bytes32 root);

    /// @notice `payload` is `abi.encode(root, authorityCounter, BootstrapLeaf, bytes32[] proof)`.
    function bootstrap(bytes calldata payload, bytes[] calldata attributes) external payable;

    /// @notice Record `root` for `relayLeaf`. Stores no signatures: each relay supplies the
    ///         signed registration from this call's source transaction.
    function registerRoot(bytes32 root) external;

    /// @notice Pay to deliver one unused leaf of a registered root, using its attributes.
    /// @dev Refunds excess payment to the caller and preserves this transmitter's balance.
    function relayLeaf(
        SafeTxEvidence calldata registrationEvidence,
        ExecutionLeaf calldata leaf,
        bytes32[] calldata proof
    ) external payable returns (bytes32 sendId);
}

/// @notice What a transceiver asks of the transmitter logic for a signed conduit, after arming
///         it with its plain initializer.
interface ISignedTransmitterInit {
    /// @param records The creation records, `abi.encode(SafeAuthorityRecord[])`, whose hash is the graph.
    function initializeSigned(bytes calldata records) external;
}
