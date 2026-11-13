// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Call} from "crossecute/messaging/Call.sol";
import {AuthoritySelection, AuthorityUpdate} from "./AuthorityUpdateTypes.sol";

/// @notice Proposed #109 additions to the shared guard; the current CrossecuteGuard does not implement them.
interface ISourceAuthorityGuard {
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
}
