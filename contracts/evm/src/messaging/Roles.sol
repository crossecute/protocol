// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title Roles
/// @notice Which transports may carry this contract's messages, in either direction.
///
/// @dev `GATEWAY_ROLE` names addresses, not powers: a gateway can neither configure a contract
///      nor grant anything. Configuration is `Ownable` on the hub. Sending and receiving check
///      the same role, so a contract cannot accept deliveries from one transport while sending
///      through another. `ReceiverBase` inherits this directly: it never sends, but the role
///      guards its external `receiveMessage`.
///
/// @dev Enumerable so an operator can read the whole member set, which is fixed at
///      initialization. `AccessControlEnumerableUpgradeable` compiles at `paris` only through
///      OZ 5.4, since 5.5's `Arrays` uses `mcopy`; a bump past 5.4 breaks this inheritance
///      first (`docs/todo.md` §4).
abstract contract Roles is AccessControlEnumerableUpgradeable {
    /// @notice May deliver a message to this contract and carry one out of it. The only role.
    /// @dev Namespaced so a provider SDK's own role of the same name cannot share its members.
    bytes32 public constant GATEWAY_ROLE = keccak256("crossecute.role.GATEWAY");

    /// @notice Grant a role. THE ONLY GRANT PATH, AND IT CLOSES WHEN INITIALIZATION DOES.
    ///
    /// @dev `onlyInitializing` replaces OZ's admin gate. No role has an admin, so after arming
    ///      no caller can add a member: not the owner, the msig, the creating transceiver, or a
    ///      member. The window includes the bootstrap payload, which `__ReceiverBase_init` runs
    ///      while initializing, so an owner's first payload can name its account's gateway.
    ///
    /// @dev `public` because it overrides OZ's `grantRole`; a separate entry point would leave
    ///      the inherited one reachable.
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
        onlyInitializing
    {
        _grantRole(role, account);
    }

    /// @notice Whether `account` holds `role`.
    /// @dev Re-declared so an override below names one base rather than both
    ///      `AccessControlUpgradeable` and `IAccessControl`.
    function hasRole(bytes32 role, address account)
        public
        view
        virtual
        override(AccessControlUpgradeable, IAccessControl)
        returns (bool)
    {
        return super.hasRole(role, account);
    }
}
