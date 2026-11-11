// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTxEvidence, ExecutionLeaf} from "../signed/types/SignedDispatchTypes.sol";

/// @notice Permissionless submission to a receiver in signed mode.
interface ISignedReceiver {
    /// @dev An authenticated repeat of a standalone message this receiver already executed.
    event DuplicateMessage();

    /// @notice Run a Safe-signed `sendMessage` addressed to this receiver.
    /// @dev Attached value stays here as a top-up.
    function submitMessage(SafeTxEvidence calldata evidence) external payable;

    /// @notice Run `leaf` if `proof` places it under the root `registration` signs.
    /// @dev Attached value stays here as a top-up, including on an authenticated repeat.
    function submitLeaf(
        SafeTxEvidence calldata registrationEvidence,
        ExecutionLeaf calldata leaf,
        bytes32[] calldata proof
    ) external payable;
}

/// @notice What a transceiver asks of the receiver logic for a signed conduit. The receiver is
///         armed first with its plain initializer and no calls, then `initializeSigned` in the
///         same transaction.
interface ISignedReceiverInit {
    /// @notice The graph hash of the creation records in `body`, `abi.encode(SignedBootstrap)`.
    /// @dev Asked of the implementation to derive addresses; the records are validated at init.
    function bootstrapGraph(bytes calldata body) external pure returns (bytes32);

    /// @param sourceChainId The EIP-155 id of the home chain, which is the Safe domain's.
    /// @param owner The conduit's owner, which the root record must name.
    /// @param graph The graph hash the conduit's address commits to.
    function initializeSigned(uint256 sourceChainId, address owner, bytes32 graph, bytes calldata body) external;

    /// @notice Reverts unless `body` is a currently valid repeat of the bootstrap that
    ///         initialized this receiver.
    function requireBootstrapRepeat(bytes calldata body) external view;
}
