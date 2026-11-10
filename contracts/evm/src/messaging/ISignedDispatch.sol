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
    bytes[] attributes; // Provider options committed by the leaf hash.
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

/// @notice Proposed interface for the shared transmitter in signed mode.
interface ISignedTransmitter is IERC7786GatewaySource {
    /// @notice Cache the owner's Safe authorization for a Merkle root.
    function registerRoot(bytes32 root) external;

    /// @notice Pay to deliver one unused leaf using its proven attributes.
    function relayLeaf(bytes32 root, ExecutionLeaf calldata leaf, bytes32[] calldata proof)
        external
        payable
        returns (bytes32 sendId);
}

/// @notice Proposed permissionless submission interface for the shared receiver in signed mode.
interface ISignedReceiver {
    event DuplicateMessage();

    /// @notice Submit a standalone Safe-signed send to its signed recipient.
    function submitDirect(SignedDelivery calldata delivery) external;

    /// @notice Submit a leaf directly using its signed root registration and proof.
    function submitDirect(SignedDelivery calldata delivery, ExecutionLeaf calldata leaf, bytes32[] calldata proof)
        external;
}
