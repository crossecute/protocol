// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTxEvidence} from "../signed/types/SignedDispatchTypes.sol";
import {AuthorityGraph} from "./AuthorityGraph.sol";

/// @notice The starting point of a Safe that a new graph adds.
/// @dev A Safe installs the guard before any parent adds it, and the guard accepts installation
///      only while the Safe still has its creation owners and threshold. graph is therefore the
///      Safe's creation-state graph, rooted at that Safe, and creationWitness is the same Safe
///      creation proof a root's initial registration uses. The Safe's first position is the
///      genesis head of graph.
struct ChildGenesis {
    AuthorityGraph graph;
    bytes creationWitness;
}

/// @notice One signed update of a descendant Safe, moving its position forward by one.
/// @dev evidence is the descendant's own registerOwnershipChange or selectAuthority SafeTx. Its
///      SafeTx hash is the new position and its signed previousUpdateHash is the position before
///      it. A registerOwnershipChange link changes the descendant's record to the result of its
///      signed mutations; a selectAuthority link moves the position only.
struct ChildLink {
    address safe;
    SafeTxEvidence evidence;
}

/// @notice What a signed update's hashes commit to, supplied beside the signed SafeTx on source
///         and on every destination.
/// @dev Every descendant in newGraph is in one of three cases. Retained at its stored position:
///      no entry. Retained and moved forward: links from the stored position. Added: one
///      introduced entry, then links from its genesis head. links are oldest first per Safe and
///      are verified against records in the root's graph, never against the descendant's own
///      selection.
struct UpdateWitness {
    AuthorityGraph newGraph;
    ChildGenesis[] introduced;
    ChildLink[] links;
}
