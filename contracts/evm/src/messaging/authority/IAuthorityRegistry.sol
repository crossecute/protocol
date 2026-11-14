// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AuthoritySelection} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {SafeTxEvidence} from "../signed/types/SignedDispatchTypes.sol";
import {AuthorityGraph} from "./AuthorityGraph.sol";
import {UpdateWitness} from "./AuthorityWitness.sol";

/// @notice Proposed provider-shared #109 registry interface, not wired into current receivers.
interface IAuthorityRegistry {
    event AuthoritySelected(
        uint256 indexed sourceChainId, address indexed sourceSafe, bytes32 indexed updateHead, bytes32 authorityHash
    );

    /// @notice Verify and apply the next signed linked update for this source identity.
    /// @dev Source identity is explicit because existing SafeTxEvidence contains no Safe address/chain.
    ///      witness carries the replacement graph and the proof of every descendant position
    ///      it adds or moves.
    function submitAuthority(
        uint256 sourceChainId,
        address sourceSafe,
        SafeTxEvidence calldata evidence,
        UpdateWitness calldata witness
    ) external;

    function selection(uint256 sourceChainId, address sourceSafe) external view returns (AuthoritySelection memory);

    function graph(bytes32 authorityHash) external view returns (AuthorityGraph memory);
}
