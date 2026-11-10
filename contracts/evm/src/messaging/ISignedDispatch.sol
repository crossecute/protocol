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
interface ISignedTransmitter is IERC7786GatewaySource {
    /// @notice Cache the owner's Safe authorization for a Merkle root.
    function registerRoot(bytes32 root) external;

    /// @notice Deliver one unused leaf proven under a registered root.
    function relayLeaf(bytes32 root, ExecutionLeaf calldata leaf, bytes32[] calldata proof, bytes[] calldata attributes)
        external
        payable
        returns (bytes32 sendId);
}

/// @notice Proposed permissionless submission interface for a Safe-signed receiver.
interface ISignedReceiver {
    event DuplicateMessage();

    /// @notice Submit a standalone Safe-signed send to its signed recipient.
    function submitDirect(SignedDelivery calldata delivery) external;
}
