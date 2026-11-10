// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICrossecuteGuard} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
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
    bytes32 merkleRoot;
    uint256 authorityCounter;
    ExecutionLeaf selectedLeaf;
    bytes32[] selectedProof;
}

/// @notice Signed child approval keyed by the child Safe and its Safe message hash.
struct NestedApproval {
    address childSafe;
    bytes32 messageHash;
    ICrossecuteGuard.SignedSafeTx approval;
}

/// @notice Safe authorization shared by provider and direct delivery.
struct SignedDelivery {
    ICrossecuteGuard.SafeTx safeTx;
    bytes signatures;
    NestedApproval[] nestedApprovals;
}

/// @notice Proposed Safe-signed transmitter interface.
/// @dev `sendMessage` takes an encoded `DispatchPayload` and routes using its selected leaf.
interface ISignedTransmitter is IERC7786GatewaySource {}

/// @notice Proposed permissionless submission interface for a Safe-signed receiver.
interface ISignedReceiver {
    event DuplicateMessage();

    /// @notice Submit one leaf and proof against the root in the original signed Safe calldata.
    /// @param delivery Full signed Safe transaction, original signatures and nested approval evidence.
    /// @param leaf The leaf to execute on this receiver.
    /// @param proof Sibling hashes proving membership in the signed root.
    function submitDirect(SignedDelivery calldata delivery, ExecutionLeaf calldata leaf, bytes32[] calldata proof)
        external;
}
