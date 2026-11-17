// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AuthorityGraph} from "crossecute/messaging/authority/AuthorityGraph.sol";
import {ChildUpdate} from "crossecute/messaging/authority/ChildUpdate.sol";
import {NestedSafeApproval} from "crossecute/messaging/signed/types/SignedDispatchTypes.sol";
import {AuthoritySelection, AuthorityUpdate} from "./AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "./ISourceAuthorityGuard.sol";

/// @notice Non-deployable #109 integration template. It grants no source authority.
/// @dev Integrate with CrossecuteGuard only after implementing activation, stageUpdate staging
///      under the per-Safe nesting lock, the portable check and recognition of the one-SafeTx
///      ownership batch. No empty-success defaults are provided for the missing machinery.
abstract contract SourceAuthorityGuardTemplate is ISourceAuthorityGuard {
    error AuthorityGuardNotImplemented();

    /// @inheritdoc ISourceAuthorityGuard
    function stageUpdate(
        address,
        AuthorityGraph calldata,
        ChildUpdate[] calldata,
        bytes calldata,
        NestedSafeApproval[] calldata
    ) external pure virtual {
        revert AuthorityGuardNotImplemented();
    }

    /// @inheritdoc ISourceAuthorityGuard
    function activate(bytes32) external pure virtual {
        revert AuthorityGuardNotImplemented();
    }

    /// @inheritdoc ISourceAuthorityGuard
    function registerOwnershipChange(AuthorityUpdate calldata) external pure virtual {
        revert AuthorityGuardNotImplemented();
    }

    /// @inheritdoc ISourceAuthorityGuard
    function selectAuthority(AuthorityUpdate calldata) external pure virtual {
        revert AuthorityGuardNotImplemented();
    }

    /// @inheritdoc ISourceAuthorityGuard
    function selection(address) external view virtual returns (AuthoritySelection memory);

    /// @inheritdoc ISourceAuthorityGuard
    function executed(address, bytes32) external view virtual returns (bool);
}
