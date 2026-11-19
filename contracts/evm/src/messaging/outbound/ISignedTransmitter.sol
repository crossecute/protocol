// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTxEvidence, ExecutionLeaf} from "../signed/types/SignedDispatchTypes.sol";

/// @notice A transmitter in signed mode: the owner calls, and the permissionless relay.
interface ISignedTransmitter {
    error RootAlreadyRegistered(bytes32 root);

    /// @notice Send receiver setup with the guard's selected authority head and graph.
    /// @dev The payload body is abi.encode(SignedBootstrap), whose authority field is
    ///      abi.encode(AuthorityGraph). The guard stages this selector, and the transmitter consumes the
    ///      record, so only a signed owner transaction can call it.
    function bootstrap(bytes calldata payload, bytes[] calldata attributes) external payable;

    /// @notice Register an owner-authorized root for later permissionless leaf relays.
    /// @dev Only the root is stored: each relayer supplies the signed registration and leaf proof.
    function registerRoot(bytes32 root) external;

    /// @notice Relay a published abi.encode(SafeTxEvidence, AuthorityGraph, ChildUpdate[]) to
    ///         this conduit's receiver, funded by the caller. Retries are allowed.
    function relayAuthority(bytes calldata recipient, bytes calldata submission, bytes[] calldata attributes)
        external
        payable
        returns (bytes32 sendId);

    /// @notice Price the same publication, route and wire bytes as relayAuthority.
    function quoteAuthority(bytes calldata recipient, bytes calldata submission, bytes[] calldata attributes)
        external
        view
        returns (uint256 fee);

    /// @notice Pay to transmit one unused leaf authorized by a registered root and signed registration.
    /// @dev Excess payment and synchronous refunds return to the caller, preserving the
    ///      transmitter's prior balance.
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
