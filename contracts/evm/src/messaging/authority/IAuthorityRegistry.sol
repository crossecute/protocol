// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AuthoritySelection} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {SafeAuthorityRecord} from "../signed/types/SafeAuthorityTypes.sol";
import {SafeTxEvidence} from "../signed/types/SignedDispatchTypes.sol";
import {AuthorityGraph} from "./AuthorityGraph.sol";
import {ChildUpdate} from "./ChildUpdate.sol";

/// @notice Proposed provider-shared #109 registry interface, not wired into current receivers.
interface IAuthorityRegistry {
    event AuthoritySelected(
        uint256 indexed sourceChainId, address indexed sourceSafe, bytes32 indexed updateHead, bytes32 authorityHash
    );

    /// @notice Verify and apply the next signed update for this source identity: the Safe's
    ///         activation while it is unregistered, otherwise a successor of its stored head.
    /// @dev Source identity is explicit because SafeTxEvidence contains no Safe address/chain.
    ///      newGraph must hash to the signed graph hash; childUpdates prove every descendant
    ///      position it adds or moves.
    function submitAuthority(
        uint256 sourceChainId,
        address sourceSafe,
        SafeTxEvidence calldata evidence,
        AuthorityGraph calldata newGraph,
        ChildUpdate[] calldata childUpdates
    ) external;

    function selection(uint256 sourceChainId, address sourceSafe) external view returns (AuthoritySelection memory);

    function graph(bytes32 authorityHash) external view returns (AuthorityGraph memory);

    function record(bytes32 recordHash) external view returns (SafeAuthorityRecord memory);
}
