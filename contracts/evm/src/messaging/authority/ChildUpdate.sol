// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeAuthorityRecord} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {SafeTxEvidence} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {AuthorityEntry} from "./AuthorityGraph.sol";

/// @notice One signed successor update of a descendant Safe: ownership change or
///         selectAuthority. Activations are not accepted.
/// @dev Its SafeTx hash is the position it creates. newGraphEntries are the entries of the
///      descendant's new graph, checked against the graph hash it signs, and name the positions
///      its nested Safe voters count under. newRecord is its new record and must hash to
///      newGraphEntries[0].recordHash; it carries the kinds of owners the update adds, which
///      hashes alone do not.
struct ChildUpdate {
    address sourceSafe;
    SafeTxEvidence evidence;
    SafeAuthorityRecord newRecord;
    AuthorityEntry[] newGraphEntries;
}
