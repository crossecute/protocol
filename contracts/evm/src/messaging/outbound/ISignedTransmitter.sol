// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTxEvidence, ExecutionLeaf} from "../signed/types/SignedDispatchTypes.sol";

/// @notice A transmitter in signed mode: the owner calls, and the permissionless relay.
interface ISignedTransmitter {
    error RootAlreadyRegistered(bytes32 root);

    /// @notice Send the owner's receiver setup with the Safe's live authority records.
    /// @dev `payload` is `bootstrapPayload(destinationChainIdentifier, payloadForCalls(calls))`,
    ///      as in plain mode. The guard stages this selector, and the transmitter consumes the
    ///      record, so only a signed owner transaction can call it.
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
    /// @notice Enable signed mode once.
    function initializeSigned() external;

    /// @notice Whether this transmitter is in signed mode.
    function isSigned() external view returns (bool);
}
