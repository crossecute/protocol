// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTxEvidence, ExecutionLeaf} from "../signed/types/SignedDispatchTypes.sol";

/// @notice A transmitter in signed mode: the owner calls, and the permissionless relay.
interface ISignedTransmitter {
    error RootAlreadyRegistered(bytes32 root);

    /// @notice Submit the owner's signed receiver-setup authorization for transmission.
    /// @dev This starts signed receiver creation and allows a failed transport send to remain
    ///      retryable. `payload` encodes the root, authority counter, bootstrap leaf and proof.
    function bootstrap(bytes calldata payload, bytes[] calldata attributes) external payable;

    /// @notice Register an owner-authorized root for later permissionless leaf relays.
    /// @dev Store only the root: each relayer supplies the signed registration and leaf proof,
    ///      avoiding a stored copy of every signature bundle.
    function registerRoot(bytes32 root) external;

    /// @notice Pay to transmit one unused leaf authorized by a registered root and signed
    ///         registration.
    /// @dev Anyone can advance a batch without another owner transaction. Excess payment and
    ///      synchronous refunds return to the caller, preserving the transmitter's prior
    ///      balance.
    function relayLeaf(
        SafeTxEvidence calldata registrationEvidence,
        ExecutionLeaf calldata leaf,
        bytes32[] calldata proof
    ) external payable returns (bytes32 sendId);
}

/// @notice What a transceiver asks of the transmitter logic for a signed conduit, after arming
///         it with its plain initializer.
interface ISignedTransmitterInit {
    /// @notice Store the encoded creation records and enable signed mode once.
    /// @dev The transceiver uses the same records to derive conduit addresses and initialize
    ///      destination authority, so signed sends must retain that snapshot.
    /// @param records The creation records, `abi.encode(SafeAuthorityRecord[])`, whose hash is the graph.
    function initializeSigned(bytes calldata records) external;
}
