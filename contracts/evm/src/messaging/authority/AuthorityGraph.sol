// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeAuthorityRecord} from "../signed/types/SafeAuthorityTypes.sol";

/// @dev Immediate owners per Safe in a stored graph and at every step of an ownership change
///      (D87). No aggregate or depth cap.
uint256 constant MAX_SAFE_OWNERS = 16;

/// @notice One Safe in a root's graph and the position of that Safe the root last adopted.
/// @dev position is an update head in record.safe's own update list. It is zero for the root,
///      whose position is the selection's updateHead.
struct AuthorityNode {
    SafeAuthorityRecord record;
    bytes32 position;
}

/// @notice A root Safe's complete selected graph, including its chosen descendant snapshots.
/// @dev nodes are in canonical depth-first order, so nodes[0] is the root. Stored graphs are
///      acyclic. A node for B here is independent of B's own root selection in the registry.
struct AuthorityGraph {
    AuthorityNode[] nodes;
}

/// @notice The hashed form of one node. The graph hash covers one entry per node.
struct AuthorityEntry {
    bytes32 recordHash;
    bytes32 position;
}
