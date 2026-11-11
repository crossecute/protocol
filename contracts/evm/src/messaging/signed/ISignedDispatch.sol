// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTx, SignedSafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {ISignedOwnerCalls} from "src/messaging/signed/ISignedOwnerCalls.sol";

/// @dev Owner kinds in a `SafeRecord`. Any other value is rejected.
uint8 constant OWNER_EOA = 0;
uint8 constant OWNER_SAFE = 1;

/// @notice One immediate owner of a Safe. A nested Safe owner refers to the record with its
///         address, never to a position in the record list.
struct OwnerEntry {
    address owner;
    uint8 kind;
}

/// @notice One Safe's authority: its threshold and its owners in `getOwners()` order.
struct SafeRecord {
    address safe;
    uint256 threshold;
    OwnerEntry[] owners;
}

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

/// @notice The setup batch a receiver runs when it is created. It has no local nonce.
struct BootstrapLeaf {
    bytes destination;
    uint256 validAfter;
    uint256 deadline;
    bytes setupCalls;
}

/// @notice A child Safe's signed `signMessage` transaction, standing in for an empty nested
///         signature. `messageHash` is the child-domain Safe message hash it approves.
struct NestedApproval {
    address childSafe;
    bytes32 messageHash;
    SignedSafeTx approval;
}

/// @notice A Safe transaction with the exact signed calldata in `safeTx.data`, the parent
///         signature blob as submitted, and the approvals its empty nested signatures need at
///         any depth.
struct SignedDelivery {
    SafeTx safeTx;
    bytes signatures;
    NestedApproval[] nestedApprovals;
}

/// @notice The body of a signed bootstrap envelope: the signed `bootstrap` call, then the
///         transmitter's creation records in canonical order.
struct SignedBootstrap {
    SignedDelivery delivery;
    SafeRecord[] records;
}

/// @dev Leading word of a signed provider message, so each wire format has one decoder.
/// @dev A standalone message is `abi.encode(STANDALONE, SignedDelivery)` over a signed
///      `sendMessage`. A Merkle message is `abi.encode(MERKLE, SignedDelivery, ExecutionLeaf,
///      bytes32[])` over a signed `registerRoot`.
uint256 constant WIRE_STANDALONE = 1;
uint256 constant WIRE_MERKLE = 2;

/// @notice A transmitter in signed mode: the owner calls, and the permissionless relay.
interface ISignedTransmitter is ISignedOwnerCalls {
    error RootAlreadyRegistered(bytes32 root);

    /// @notice Pay to deliver one unused leaf of a registered root, using its attributes.
    /// @dev Refunds excess payment to the caller and preserves this transmitter's balance.
    function relayLeaf(SignedDelivery calldata registration, ExecutionLeaf calldata leaf, bytes32[] calldata proof)
        external
        payable
        returns (bytes32 sendId);
}

/// @notice Permissionless submission to a receiver in signed mode.
interface ISignedReceiver {
    /// @dev An authenticated repeat of a standalone message this receiver already executed.
    event DuplicateMessage();

    /// @notice Run a Safe-signed `sendMessage` addressed to this receiver.
    /// @dev Attached value stays here as a top-up.
    function submitMessage(SignedDelivery calldata delivery) external payable;

    /// @notice Run `leaf` if `proof` places it under the root `registration` signs.
    /// @dev Attached value stays here as a top-up, including on an authenticated repeat.
    function submitLeaf(SignedDelivery calldata registration, ExecutionLeaf calldata leaf, bytes32[] calldata proof)
        external
        payable;
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

/// @notice What a transceiver asks of the transmitter logic for a signed conduit, after arming
///         it with its plain initializer.
interface ISignedTransmitterInit {
    /// @param records The creation records, `abi.encode(SafeRecord[])`, whose hash is the graph.
    function initializeSigned(bytes calldata records) external;
}
