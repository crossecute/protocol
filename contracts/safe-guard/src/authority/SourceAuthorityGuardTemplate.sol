// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Call} from "crossecute/messaging/Call.sol";
import {AuthoritySelection, AuthorityUpdate} from "./AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "./ISourceAuthorityGuard.sol";

/// @notice Non-deployable #109 integration template. It grants no source authority.
/// @dev Integrate with CrossecuteGuard only after implementing portable pre-hook staging,
///      real Safe caller/configuration checks and invocation-scoped pair completion.
///      No empty-success defaults are provided for the missing security machinery.
abstract contract SourceAuthorityGuardTemplate is ISourceAuthorityGuard {
    error AuthorityGuardNotImplemented();

    /// @inheritdoc ISourceAuthorityGuard
    function registerOwnershipChange(AuthorityUpdate calldata, Call[] calldata) external pure virtual {
        revert AuthorityGuardNotImplemented();
    }

    /// @inheritdoc ISourceAuthorityGuard
    function selectAuthority(AuthorityUpdate calldata) external pure virtual {
        revert AuthorityGuardNotImplemented();
    }

    /// @inheritdoc ISourceAuthorityGuard
    function selection(address) external view virtual returns (AuthoritySelection memory);
}
