// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Call} from "crossecute/messaging/Call.sol";
import {UpdateWitness} from "crossecute/messaging/authority/AuthorityWitness.sol";
import {AuthoritySelection, AuthorityUpdate} from "./AuthorityUpdateTypes.sol";

/// @notice Proposed #109 additions to the shared guard; the current CrossecuteGuard does not implement them.
interface ISourceAuthorityGuard {
    /// @notice The evidence destinations accept for an executed update.
    /// @dev portableSignatures is the set the guard verified under the selected graph, which
    ///      can differ from the signatures the Safe executed with.
    event AuthorityUpdateExecuted(
        address indexed sourceSafe, bytes32 indexed updateHead, bytes32 authorityHash, bytes portableSignatures
    );

    /// @notice Supplies what the next update's hashes commit to. Callable by anyone, held for
    ///         the current transaction only.
    /// @dev The witness is the one destinations receive. Every descendant position it names
    ///      must satisfy executed(). portableSignatures is empty when the executing signatures
    ///      also pass the portable check; otherwise the guard verifies this set.
    function stageUpdate(address sourceSafe, UpdateWitness calldata witness, bytes calldata portableSignatures) external;

    /// @notice Registers the first SafeTx of an atomic registration/ownership-batch pair.
    /// @dev The next Safe nonce must delegatecall the pinned MultiSendCallOnly with exactly
    ///      these zero-value self-CALLs. Pair completion and source post-state are mandatory.
    ///      The registration SafeTx hash becomes the completed source update head.
    function registerOwnershipChange(AuthorityUpdate calldata update, Call[] calldata mutations) external;

    /// @notice Authorizes a complete tracked graph replacement without changing root source ownership.
    /// @dev Must authenticate the Safe caller, portable quorum, prior head and descendant witnesses.
    ///      The signed SafeTx hash becomes the new source head. No destination fields are signed.
    function selectAuthority(AuthorityUpdate calldata update) external;

    /// @notice Source-side selection for a Safe, separate from destination selections.
    function selection(address sourceSafe) external view returns (AuthoritySelection memory);

    /// @notice Whether updateHead is a position sourceSafe executed on this chain.
    /// @dev Written when the Safe installs the guard (its genesis head) and when one of its
    ///      updates executes, so a Safe's executed heads form one list with no forks. Covers
    ///      every executed head, not only the current one.
    function executed(address sourceSafe, bytes32 updateHead) external view returns (bool);
}
