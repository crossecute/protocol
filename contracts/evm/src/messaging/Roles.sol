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
///      nor grant anything. Configuration is `Ownable` on the transceiver, except bootstrap fees,
///      which an operator the owner names may also set. Sending and receiving check
///      the same role, so a contract cannot accept deliveries from one transport while sending
///      through another. `ReceiverBase` inherits this directly: it never sends, but the role
///      guards its external `receiveMessage`.
///
/// @dev Not enumerable here: a transceiver's members are fixed at initialization, each grant
///      emits `RoleGranted`, and enumeration would cost every transceiver a kilobyte it does
///      not have under EIP-170 (#29). Conduits, whose receivers can revoke, add it through
///      `RolesEnumerable`.
abstract contract Roles is AccessControlUpgradeable {
    /// @notice May deliver a message to this contract and carry one out of it. The only role.
    /// @dev Namespaced so a provider SDK's own role of the same name cannot share its members.
    bytes32 public constant GATEWAY_ROLE = keccak256("crossecute.role.GATEWAY");

    /// @dev The caller of `grantRole` was not this contract.
    error GrantNotFromSelf(address caller);

    /// @notice Grant a role from this contract's own bootstrap payload, so an owner's first
    ///         payload can name its conduit's gateway. Closes when initialization does.
    ///
    /// @dev `onlyInitializing` replaces OZ's admin gate. No role has an admin, so after arming
    ///      no caller can add a member: not the owner, the governor, the creating transceiver, or a
    ///      member. The flag stays set while `__ReceiverBase_init` runs the payload, so every
    ///      contract the payload reaches would be inside the window too; only a self-call from
    ///      `_execute` is accepted (#68).
    ///
    /// @dev `public` because it overrides OZ's `grantRole`; a separate entry point would leave
    ///      the inherited one reachable.
    function grantRole(bytes32 role, address conduit) public virtual override onlyInitializing {
        if (msg.sender != address(this)) revert GrantNotFromSelf(msg.sender);
        _grantRole(role, conduit);
    }

    /// @notice An initializer's own grant, such as the provider endpoint it names as a gateway.
    function _grantInitialRole(bytes32 role, address conduit) internal onlyInitializing {
        _grantRole(role, conduit);
    }

    /// @notice Whether `conduit` holds `role`.
    /// @dev Re-declared so an override below names one base.
    function hasRole(bytes32 role, address conduit) public view virtual override returns (bool) {
        return super.hasRole(role, conduit);
    }
}

/// @title RolesEnumerable
/// @notice `Roles`, with the member set readable on-chain, for conduits: a receiver can drop a
///         gateway through `revokeGateway`, so what remains is worth reading directly.
/// @dev `AccessControlEnumerableUpgradeable` compiles at `paris` only through OZ 5.4, since
///      5.5's `Arrays` uses `mcopy`; a bump past 5.4 breaks this inheritance first (README,
///      Assumptions).
abstract contract RolesEnumerable is Roles, AccessControlEnumerableUpgradeable {
    function grantRole(bytes32 role, address conduit)
        public
        virtual
        override(Roles, AccessControlUpgradeable, IAccessControl)
        onlyInitializing
    {
        super.grantRole(role, conduit);
    }

    function hasRole(bytes32 role, address conduit)
        public
        view
        virtual
        override(Roles, AccessControlUpgradeable, IAccessControl)
        returns (bool)
    {
        return super.hasRole(role, conduit);
    }

    function _grantRole(bytes32 role, address conduit)
        internal
        virtual
        override(AccessControlUpgradeable, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return super._grantRole(role, conduit);
    }

    function _revokeRole(bytes32 role, address conduit)
        internal
        virtual
        override(AccessControlUpgradeable, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return super._revokeRole(role, conduit);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlUpgradeable, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
