// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IERC7786GatewaySource} from "src/messaging/IErc7786.sol";

/// @notice Proposed leaf for an ordered batch on one receiver.
struct ExecutionLeaf {
    bytes destination; // Full ERC-7930 destination address.
    uint256 localNonce;
    uint256 validAfter;
    uint256 deadline;
    bytes callPayload; // abi.encode(Call[]) for EVM destinations.
}

/// @notice Proposed `sendMessage` payload, encoded as one ABI tuple with `abi.encode(dispatch)`.
struct DispatchPayload {
    uint256 authorityCounter;
    bytes32 merkleRoot;
    ExecutionLeaf selectedLeaf;
    bytes32[] selectedProof;
}

/// @notice Proposed Safe-signed transmitter interface.
/// @dev `sendMessage` takes an encoded `DispatchPayload` and routes using its selected leaf.
interface ISignedTransmitter is IERC7786GatewaySource {}

/// @notice Proposed permissionless submission interface for a Safe-signed receiver.
interface ISignedReceiver {
    event DuplicateMessage();

    /// @notice Submit one leaf and proof against the root in the original signed Safe calldata.
    /// @param signedSafeTxContext Safe transaction context including the exact `sendMessage` calldata.
    /// @param safeSignatures The Safe owners' signature bundle.
    /// @param nestedApprovalEvidence Supplemental evidence for empty nested Safe signatures, if any.
    /// @param leaf The leaf to execute on this receiver.
    /// @param proof Sibling hashes proving membership in the signed root.
    function submitDirect(
        bytes calldata signedSafeTxContext,
        bytes calldata safeSignatures,
        bytes calldata nestedApprovalEvidence,
        ExecutionLeaf calldata leaf,
        bytes32[] calldata proof
    ) external;
}
