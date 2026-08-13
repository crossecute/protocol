// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IAccessControlEnumerable} from
    "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title Roles
/// @notice The two role-shaped facts every contract here recognises, and the only two.
///
/// @dev NEITHER OF THESE IS AN AUTHORITY, AND THAT IS THE POINT. `TREASURY` is where fees may
///      go; `GATEWAY` is which transport may carry this contract's messages. Both are
///      addresses a deployment names, not powers a holder exercises: a treasury cannot
///      configure a transceiver and a gateway cannot grant itself anything. Configuration is
///      `Ownable` on the transceiver, deliberately somewhere else, so the address that gets
///      PAID and the address that DECIDES are never the same fact.
///
/// @dev A MEMBERSHIP RATHER THAN A PREDICATE, because the question is "which addresses", not
///      "is this one". Both were once a virtual each concrete contract answered from whatever
///      it had, which meant every binding re-implemented authorization and the answers were
///      only as good as the binding's care.
///
/// @dev BOTH DIRECTIONS ASK FOR `GATEWAY`, which is the property the seam exists for. A
///      contract that accepted deliveries from one address while sending through another would
///      be trusting two transports and authenticating against one, and nothing would say so:
///      the send would work and only a message from the second gateway would be silently
///      refused. One role, held or not, makes that unrepresentable. `ReceiverBase` inherits
///      this directly rather than through `OutboundBase` because a receiver never sends, yet
///      it is the contract with the strictest need to know which gateway is real, since
///      `receiveMessage` is `external` and this check is one of the two things in front of it.
///
/// @dev ENUMERABLE BECAUSE "WHO ELSE" IS THE QUESTION THAT MATTERS. A predicate answers only
///      about an address you already suspect, so a deployment could carry an authority nobody
///      thought to ask about. `getRoleMemberCount` / `getRoleMember` make the whole set
///      readable, which is what lets an operator — or a monitor — verify that a live
///      transceiver has exactly the treasury and exactly the gateways it should. It matters
///      more now that membership is fixed at initialization: the set cannot be corrected
///      later, so being able to read it whole is how a mistake is caught while a redeploy is
///      still cheap.
///
/// @dev THE ENUMERATION IS OURS RATHER THAN OZ's, AND THE REASON IS THE EVM VERSION. OZ's
///      `AccessControlEnumerableUpgradeable` reaches `EnumerableSet`, which reaches `Arrays`,
///      which emits `mcopy` and so requires Cancun. This protocol is pinned to `paris` because
///      identical bytecode on every chain is what the CREATE2 derivation depends on and PUSH0
///      alone is already absent on zkSync and Tron; a Cancun opcode in a SPOKE transceiver
///      would not merely change an address, it would fail to execute. So the roles are OZ's
///      `AccessControlUpgradeable`, the interface is OZ's `IAccessControlEnumerable`, and the
///      member list below is a swap-and-pop array that compiles under paris.
abstract contract Roles is AccessControlUpgradeable, IAccessControlEnumerable {
    /// @notice Where collected fees may be withdrawn to, and nothing else.
    /// @dev IT NAMES A DESTINATION, NOT A CALLER. `withdrawFees` asks whether the address it
    ///      was handed holds this, which is the question no caller-shaped check can express:
    ///      without it the owner could name any address at all, and a fee taken to fund
    ///      spokes could leave to somewhere that funds none. Holding it confers no ability to
    ///      call anything.
    /// @dev NAMESPACED RATHER THAN `keccak256("TREASURY")`. A role is just a bytes32, so two
    ///      contracts in one inheritance tree that pick the same string share the same member
    ///      set, and a provider SDK with a role of that name would silently share this one.
    bytes32 public constant TREASURY_ROLE = keccak256("crossecute.role.TREASURY");

    /// @notice May deliver a message to this contract, and may carry one out of it.
    bytes32 public constant GATEWAY_ROLE = keccak256("crossecute.role.GATEWAY");

    /// @custom:storage-location erc7201:crossecute.storage.Roles
    struct RolesStorage {
        mapping(bytes32 role => address[]) members;
        /// One-based, so zero means absent and the mapping needs no companion flag.
        mapping(bytes32 role => mapping(address member => uint256)) position;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("crossecute.storage.Roles")) - 1)) & ~0xff
    bytes32 private constant ROLES_STORAGE =
        0xf1b64cb839b8b073aa6d4a90c8a3bf8f4d7a0c2da15427a27d614371a5c91400;

    function _rolesStorage() private pure returns (RolesStorage storage $) {
        assembly {
            $.slot := ROLES_STORAGE
        }
    }

    /// @notice Grant a role. THE ONLY GRANT PATH, AND IT CLOSES WHEN INITIALIZATION DOES.
    ///
    /// @dev IT IS `onlyInitializing`, NOT ROLE-GATED, WHICH IS THE WHOLE DESIGN. OZ gates this
    ///      on `getRoleAdmin(role)`, and no role here has an administrator: `DEFAULT_ADMIN_ROLE`
    ///      is never granted to anything, so the inherited version could never succeed and the
    ///      membership would have to arrive through some internal back door instead. Replacing
    ///      the gate with the initialization window says the same thing in one place: a
    ///      contract's treasury and transports are named while it is being armed, and after
    ///      that no caller of any kind can add another. Not the owner, not the msig, not the
    ///      transceiver that created an account, not a member of the role itself.
    ///
    /// @dev IT IS `public` RATHER THAN `external` BECAUSE IT OVERRIDES ONE. Solidity permits
    ///      widening `external` to `public` in an override and not the reverse, and this must
    ///      override OZ's `grantRole` rather than sit beside it: a second entry point would
    ///      leave the inherited one reachable, and "which of the two grants" is exactly the
    ///      question this contract exists to have one answer to. Internal calls from an
    ///      initializer are what actually use it.
    ///
    /// @dev THE WINDOW REACHES THE BOOTSTRAP PAYLOAD, DELIBERATELY. `__ReceiverBase_init`
    ///      executes the payload while `_initializing` is still true, so an owner's very first
    ///      payload can name its account's gateway with a self-call. That is the owner
    ///      configuring their own account in the transaction that creates it, which is the one
    ///      moment the protocol already trusts for exactly this.
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
        onlyInitializing
    {
        _grantRole(role, account);
    }


    /// @notice Whether `account` holds `role`.
    /// @dev RE-DECLARED SO THE TREE BELOW SEES ONE DECLARATION. `Roles` inherits `hasRole`
    ///      from both `AccessControlUpgradeable` and `IAccessControlEnumerable`'s
    ///      `IAccessControl`, and Solidity then demands every further override name both
    ///      bases. Collapsing them here means a contract that wants to say something about
    ///      membership writes plain `override`, against this file rather than against OZ's
    ///      inheritance graph.
    function hasRole(bytes32 role, address account)
        public
        view
        virtual
        override(AccessControlUpgradeable, IAccessControl)
        returns (bool)
    {
        return super.hasRole(role, account);
    }

    /* ================================ enumeration ================================ */

    /// @inheritdoc IAccessControlEnumerable
    function getRoleMemberCount(bytes32 role) public view returns (uint256) {
        return _rolesStorage().members[role].length;
    }

    /// @inheritdoc IAccessControlEnumerable
    /// @dev THE ORDER IS NOT STABLE. Revoking swaps the last member into the hole, so an index
    ///      is a cursor for one read and not a handle. Callers that want the set read it whole.
    function getRoleMember(bytes32 role, uint256 index) public view returns (address) {
        return _rolesStorage().members[role][index];
    }

    /// @notice The whole set, which is what an operator or a monitor actually wants.
    function getRoleMembers(bytes32 role) public view returns (address[] memory) {
        return _rolesStorage().members[role];
    }

    /// @dev Both hooks return whether the membership actually CHANGED, so a repeated grant or
    ///      a revoke of a non-member cannot push a duplicate or pop a stranger's entry.
    function _grantRole(bytes32 role, address account)
        internal
        virtual
        override
        returns (bool granted)
    {
        granted = super._grantRole(role, account);
        if (granted) {
            RolesStorage storage $ = _rolesStorage();
            $.members[role].push(account);
            $.position[role][account] = $.members[role].length;
        }
    }

    function _revokeRole(bytes32 role, address account)
        internal
        virtual
        override
        returns (bool revoked)
    {
        revoked = super._revokeRole(role, account);
        if (revoked) {
            RolesStorage storage $ = _rolesStorage();
            address[] storage list = $.members[role];
            uint256 slot = $.position[role][account];
            address moved = list[list.length - 1];

            list[slot - 1] = moved;
            $.position[role][moved] = slot;
            list.pop();
            delete $.position[role][account];
        }
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override
        returns (bool)
    {
        return interfaceId == type(IAccessControlEnumerable).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
