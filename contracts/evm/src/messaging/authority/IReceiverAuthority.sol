// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AuthoritySelection} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {SafeAuthorityRecord} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {SafeTxEvidence} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {AuthorityGraph} from "./AuthorityGraph.sol";
import {ChildUpdate} from "./ChildUpdate.sol";

/// @notice The selected authority and authenticated updates of one signed receiver.
/// @dev The source identity is the receiver's own: its source chain and owner Safe. Its first
///      selection comes from its bootstrap, never from a submitted activation.
interface IReceiverAuthority {
    event AuthoritySelected(bytes32 indexed updateHead, bytes32 authorityHash);

    /// @notice Verify and apply the next signed update: a successor of the stored head.
    /// @dev newGraph must hash to the signed graph hash; childUpdates prove every retained
    ///      descendant position it moves, and each must be used exactly once.
    function submitAuthority(
        SafeTxEvidence calldata evidence,
        AuthorityGraph calldata newGraph,
        ChildUpdate[] calldata childUpdates
    ) external;

    function selection() external view returns (AuthoritySelection memory);

    function graph(bytes32 authorityHash) external view returns (AuthorityGraph memory);

    function record(bytes32 recordHash) external view returns (SafeAuthorityRecord memory);
}
