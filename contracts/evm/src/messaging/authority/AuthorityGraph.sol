// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeAuthorityRecord} from "../signed/types/SafeAuthorityTypes.sol";

/// @notice A root Safe's complete selected graph, including its chosen descendant snapshots.
/// @dev Reuses existing SafeOwner/SafeAuthorityRecord, including owner kind constants.
///      Canonical traversal emits each reachable identity once; stored cycles are allowed.
///      A record for B here is independent of B's own root selection in the registry.
struct AuthorityGraph {
    address rootSafe;
    SafeAuthorityRecord[] records;
}
