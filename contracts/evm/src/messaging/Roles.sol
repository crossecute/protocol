// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IAccessControlEnumerable} from
    "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title Roles
/// @notice The two authorities every contract here recognises, and the only two.
///
/// @dev ONE SYSTEM FOR BOTH, BECAUSE THEY ARE THE SAME KIND OF FACT. `ADMIN` is who may
///      configure a transceiver; `GATEWAY` is which transport may carry its messages. Both
///      were previously a virtual predicate each concrete contract answered from whatever it
///      had, which meant every binding re-implemented authorization and the answers were only
///      as good as the binding's care. They are role membership now, so the answer has one
///      shape, and a binding that adds a transport or an operator does it by granting rather
///      than by writing a comparison.
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
///      transceiver has exactly the admins and exactly the gateways it should.
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
    /// @notice Configures a transceiver: routes, counterparts, fees, the provenance bar.
    /// @dev NAMESPACED RATHER THAN `keccak256("ADMIN")`. A role is just a bytes32, so two
    ///      contracts in one inheritance tree that pick the same string share the same member
    ///      set. A provider SDK with an `ADMIN` role of its own would then silently hand its
    ///      administrators this one, which is the two-authorities failure the seam exists to
    ///      prevent, arriving through a string collision instead of an inheritance list.
    bytes32 public constant ADMIN_ROLE = keccak256("crossecute.role.ADMIN");

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

    /// @dev A transceiver was initialized with no admin, which would seal it as unusable.
    error NoAdmin();

    /// @notice Wire the role graph, and grant `admin` if there is one.
    ///
    /// @dev `DEFAULT_ADMIN_ROLE` IS NEVER GRANTED, so there is no authority above these two.
    ///      OZ's default makes `DEFAULT_ADMIN_ROLE` the administrator of every role, which
    ///      would put a third party over both of these and make "who can add a gateway" a
    ///      question with two answers. `ADMIN` administers itself and `GATEWAY`: an admin can
    ///      hand over, add an operator, or change the transport set, and nothing else can.
    ///
    /// @dev A ZERO `admin` MEANS THERE IS NO ADMIN, AND THAT IS THE ACCOUNT CASE. An account
    ///      is configured entirely in the call that arms it and is owner-gated afterwards, so
    ///      it grants its gateway during initialization and leaves `ADMIN` empty. Nothing can
    ///      grant `GATEWAY` on it after that — not the transceiver that created it, not the
    ///      msig — because granting needs an `ADMIN` and there is none. That is the same
    ///      guarantee the write-once slots give, obtained by leaving a role unheld.
    ///      `TransceiverBase` refuses a zero, since a transceiver with no admin could never
    ///      be configured at all.
    function __Roles_init(address admin) internal onlyInitializing {
        __AccessControl_init();
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(GATEWAY_ROLE, ADMIN_ROLE);
        if (admin != address(0)) _grantRole(ADMIN_ROLE, admin);
    }

    /// @notice Trust `gateway` to carry this contract's messages, in both directions.
    /// @dev Internal, so granting is an initializer's or an admin operation's decision rather
    ///      than an entry point of its own. `grantRole(GATEWAY_ROLE, ...)` is the admin path
    ///      and needs no wrapper.
    function _grantGateway(address gateway) internal {
        _grantRole(GATEWAY_ROLE, gateway);
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
