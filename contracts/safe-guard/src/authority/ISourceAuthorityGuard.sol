// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AuthorityGraph} from "crossecute/messaging/authority/AuthorityGraph.sol";
import {ChildUpdate} from "crossecute/messaging/authority/ChildUpdate.sol";
import {NestedSafeApproval} from "crossecute/messaging/signed/types/SignedDispatchTypes.sol";
import {AuthoritySelection, AuthorityUpdate} from "./AuthorityUpdateTypes.sol";

/// @notice Source authority operations and publication implemented by CrossecuteGuard.
interface ISourceAuthorityGuard {
    /// @notice The signatures destinations accept for an executed activation or update.
    event AuthorityUpdateExecuted(
        address indexed sourceSafe,
        bytes32 indexed updateHead,
        bytes32 authorityHash,
        bytes portableSignatures,
        NestedSafeApproval[] nestedApprovals
    );

    /// @notice Full portable submission verified during source execution, for relay and archival.
    event AuthorityPublished(address indexed sourceSafe, bytes32 indexed updateHead, bytes submission);

    /// @notice Hash of the exact published submission, or zero if no update was published.
    function publishedAuthority(address sourceSafe, bytes32 updateHead) external view returns (bytes32);

    /// @notice Supplies what the next activation or update of sourceSafe commits to and the
    ///         signatures destinations will verify. Callable by anyone, held for the current
    ///         transaction only.
    /// @dev newGraph must hash to the signed graph hash. Every descendant position it names
    ///      must satisfy executed(). portableSignatures is always the full set destinations
    ///      verify, even when it equals the executing signatures.
    function stageUpdate(
        address sourceSafe,
        AuthorityGraph calldata newGraph,
        ChildUpdate[] calldata childUpdates,
        bytes calldata portableSignatures,
        NestedSafeApproval[] calldata nestedApprovals
    ) external;

    /// @notice A Safe's first update, signed by its quorum after it sets the guard.
    /// @dev The initial graph's root record must equal the Safe's live owners and threshold, and
    ///      every Safe owner must already be activated. The SafeTx hash becomes the first head.
    ///      Destinations never receive it: each receiver starts from its bootstrap's head.
    function activate(bytes32 authorityHash) external;

    /// @notice The first call of a one-SafeTx ownership change.
    /// @dev The SafeTx DELEGATECALLs the pinned MultiSendCallOnly with this call followed by the
    ///      ordered zero-value owner self-calls. Its SafeTx hash becomes the new head.
    function registerOwnershipChange(AuthorityUpdate calldata update) external;

    /// @notice Authorizes a complete tracked graph replacement without changing root source ownership.
    /// @dev The signed SafeTx hash becomes the new source head. No destination fields are signed.
    function selectAuthority(AuthorityUpdate calldata update) external;

    /// @notice Source-side selection for a Safe, separate from destination selections.
    function selection(address sourceSafe) external view returns (AuthoritySelection memory);

    /// @notice Read a graph authenticated for sourceSafe, including retained past graphs.
    /// @dev Readback does not change the selected graph or prove any later child transition.
    function graph(address sourceSafe, bytes32 authorityHash) external view returns (AuthorityGraph memory);

    /// @notice Whether updateHead is a position sourceSafe executed on this chain.
    /// @dev Written at activation and whenever one of the Safe's updates executes, so a Safe's
    ///      executed heads form one list with no forks. Covers every executed head, not only the
    ///      current one.
    function executed(address sourceSafe, bytes32 updateHead) external view returns (bool);
}
