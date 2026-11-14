// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTxEvidence} from "../signed/types/SignedDispatchTypes.sol";
import {AuthorityEntry} from "./AuthorityGraph.sol";

/// @notice One signed update of a descendant Safe: its activation, ownership change or
///         selectAuthority.
/// @dev Its SafeTx hash is the position it creates. newGraphEntries are the entries of the
///      descendant's new graph, checked against the graph hash it signs, and name the positions
///      its nested Safe voters count under. They may be empty when no Safe-kind owner votes.
struct ChildUpdate {
    address sourceSafe;
    SafeTxEvidence evidence;
    AuthorityEntry[] newGraphEntries;
}
