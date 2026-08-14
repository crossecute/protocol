// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlEnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title Roles
/// @notice The one role-shaped fact every contract here recognises: which transports may
///         carry its messages.
///
/// @dev IT IS NOT AN AUTHORITY, AND THAT IS THE POINT. `GATEWAY` names addresses rather than
///      powers: a gateway cannot configure a transceiver and cannot grant itself anything.
///      Configuration is `Ownable` on the hub, deliberately somewhere else.
///
/// @dev THERE WAS A SECOND ROLE AND IT WAS THE WRONG SHAPE. `TREASURY` bounded where
///      `withdrawFees` could send an accrued balance; fees now move to the hub's `treasury`
///      address inside the bootstrap that charges them, so there is no balance to direct and
///      no operation to bound. A role answers "may this address be paid", and the question
///      was always "where does this go".
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
///      transceiver has exactly the gateways it should. It matters
///      more now that membership is fixed at initialization: the set cannot be corrected
///      later, so being able to read it whole is how a mistake is caught while a redeploy is
///      still cheap.
///
/// @dev THE ENUMERATION IS OPENZEPPELIN'S, AND THAT IS A DEPENDENCY-VERSION FACT. `Arrays`
///      picked up raw `mcopy` in OZ 5.5.0, and `EnumerableSet` imports it, so
///      `AccessControlEnumerableUpgradeable` does not COMPILE at `paris` from 5.5 onward —
///      six sites, whether or not the reaching code is ever called. The pin exists because
///      PUSH0 is absent on zkSync, Tron, and several L2s and identical initcode everywhere is
///      what the CREATE2 story rests on, so the pin wins and the dependency version follows
///      it: this repo is on 5.4.0, where the extension compiles cleanly and a hand-rolled
///      member list buys nothing. If OZ is ever bumped past 5.4, this inheritance is the
///      first thing that stops building, and forking the member list back out is the answer.
abstract contract Roles is AccessControlEnumerableUpgradeable {
    /// @notice May deliver a message to this contract, and may carry one out of it. THE ONLY
    ///         ROLE THERE IS.
    /// @dev NAMESPACED RATHER THAN `keccak256("GATEWAY")`. A role is just a bytes32, so two
    ///      contracts in one inheritance tree that pick the same string share the same member
    ///      set, and a provider SDK with a role of that name would silently share this one.
    bytes32 public constant GATEWAY_ROLE = keccak256("crossecute.role.GATEWAY");

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
    /// @dev RE-DECLARED SO THE TREE BELOW SEES ONE DECLARATION. `hasRole` arrives from both
    ///      `AccessControlUpgradeable` and `IAccessControl`, and Solidity then demands every
    ///      further override name both bases. Collapsing them here means a contract that wants
    ///      to say something about membership — a test harness that trusts any gateway, a
    ///      binding narrowing an answer — writes plain `override`, against this file rather
    ///      than against OpenZeppelin's inheritance graph.
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
