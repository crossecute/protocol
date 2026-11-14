// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeAuthorityRecord} from "../signed/types/SafeAuthorityTypes.sol";

/// @notice A root Safe's complete selected graph, including its chosen descendant snapshots.
/// @dev Reuses existing SafeOwner/SafeAuthorityRecord, including owner kind constants.
///      Canonical traversal emits each reachable identity once and rejects cycles.
///      A record for B here is independent of B's own root selection in the registry.
///      positions[i] is the update head of records[i].safe that the root last adopted, in
///      that Safe's own update list. It is zero for the root's own record, whose position
///      is the selection's updateHead.
struct AuthorityGraph {
    address rootSafe;
    SafeAuthorityRecord[] records;
    bytes32[] positions;
}
