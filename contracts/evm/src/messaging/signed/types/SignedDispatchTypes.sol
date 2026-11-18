// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SignedSafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";

/// @dev Leading word of a signed provider message, so each wire format has one decoder.
/// @dev A standalone message is `abi.encode(STANDALONE, SafeTxEvidence)` over a signed
///      `sendMessage`. A Merkle message is `abi.encode(MERKLE, SafeTxEvidence, ExecutionLeaf,
///      bytes32[])` over a signed `registerRoot`.
uint256 constant WIRE_STANDALONE = 1;
uint256 constant WIRE_MERKLE = 2;
/// @dev abi.encode(WIRE_AUTHORITY, abi.encode(SafeTxEvidence, AuthorityGraph, ChildUpdate[])).
uint256 constant WIRE_AUTHORITY = 3;

/// @notice An ordered batch for one receiver, under a registered root. Hashed by
///         `DispatchLeaves.hash`; `DispatchLeaves.executionId` omits `attributes`.
struct ExecutionLeaf {
    bytes destination; // Full ERC-7930 address of the receiver.
    uint256 nonce; // The receiver's local execution nonce.
    uint256 validAfter;
    uint256 deadline;
    bytes calls; // abi.encode(Call[]) for an EVM destination.
    bytes[] attributes; // The provider options `relayLeaf` quotes and sends with.
}

/// @notice A child Safe's signed `signMessage` transaction, standing in for an empty nested
///         signature. `messageHash` is the child-domain Safe message hash it approves.
struct NestedSafeApproval {
    address childSafe;
    bytes32 messageHash;
    SignedSafeTx approval;
}

/// @notice A Safe transaction with the exact signed calldata in `signedSafeTx.safeTx.data`, the parent
///         signature blob as submitted, and the approvals its empty nested signatures need at
///         any depth.
struct SafeTxEvidence {
    SignedSafeTx signedSafeTx;
    NestedSafeApproval[] nestedApprovals;
}

/// @notice The selected source authority and setup calls, authenticated by the bootstrap provider.
struct SignedBootstrap {
    address guard;
    bytes32 updateHead;
    bytes authority; // abi.encode(AuthorityGraph), decoded separately to retain the legacy compiler pipeline.
    bytes setupCalls; // abi.encode(Call[]).
}
