// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTxEvidence, ExecutionLeaf} from "../signed/types/SignedDispatchTypes.sol";

/// @notice A transmitter in signed mode: the owner calls, and the permissionless relay.
interface ISignedTransmitter {
    event SignedTransmitterInitialized();
    event RootRegistered(bytes32 indexed root);
    event AuthorityRelayed(bytes32 indexed updateHead, address indexed relayer);
    event LeafRelayed(bytes32 indexed leafHash, address indexed relayer);

    error NotSigned();
    error AlreadySigned();
    error OwnershipFixed();
    error SignedQuoteRequired();
    error RootNotPublished(bytes32 root);
    error RootAlreadyRegistered(bytes32 root);
    error RootNotRegistered(bytes32 root);
    error LeafAlreadyRelayed(bytes32 leafHash);
    error InsufficientPayment(uint256 fee, uint256 paid);
    error RefundFailed();
    error BalanceChanged(uint256 before, uint256 afterwards);
    error RelayReentered();
    /// @dev The destination reports its receiver or is not EVM; signed receivers are created
    ///      only where the home derives them.
    error SignedReceiverNotDerivable(bytes32 destinationChainKey);
    error NoSignedAuthority(address safe);
    error BootstrapAuthorityMismatch();
    error AuthorityNotPublished(bytes32 updateHead);

    /// @notice Send receiver setup with the guard's selected authority head and graph.
    /// @dev The payload body is abi.encode(SignedBootstrap), whose authority field is
    ///      abi.encode(AuthorityGraph). The guard stages this selector, and the transmitter consumes the
    ///      record, so only a signed owner transaction can call it.
    function bootstrap(bytes calldata payload, bytes[] calldata attributes) external payable;

    /// @notice Price the standalone signed message encoded by the Safe transaction evidence.
    function quoteMessageSigned(SafeTxEvidence calldata evidence) external view returns (uint256);

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

    /// @notice Price the relay of the supplied signed registration, leaf and proof.
    /// @dev Applies the same registration, replay and payload validation as `relayLeaf`.
    function quoteLeaf(
        SafeTxEvidence calldata registrationEvidence,
        ExecutionLeaf calldata leaf,
        bytes32[] calldata proof
    ) external view returns (uint256 fee);

    /// @notice Whether this transmitter has registered the root for relay.
    function isRootRegistered(bytes32 root) external view returns (bool);

    /// @notice Whether this transmitter has already relayed the leaf hash.
    /// @param leafHash `DispatchLeaves.hash(leaf)`.
    function isLeafRelayed(bytes32 leafHash) external view returns (bool);
}

/// @notice What a transceiver asks of the transmitter logic for a signed conduit, after arming
///         it with its base initializer.
interface ISignedTransmitterInit {
    /// @notice Enable signed mode once.
    function initializeSigned() external;

    /// @notice Whether this transmitter is in signed mode.
    function isSigned() external view returns (bool);
}
