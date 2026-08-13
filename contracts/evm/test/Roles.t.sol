// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from
    "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

import {Roles} from "src/messaging/Roles.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {LzReceiver} from "src/protocols/layerzero/LzReceiver.sol";
import {LzTransmitter} from "src/protocols/layerzero/LzTransmitter.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @dev An account names its transport in the call that arms it, which is the only moment
///      anything can: `GATEWAY` has no role admin, so no grant ever succeeds. Granting ahead of
///      `__ReceiverBase_init` is the documented shape — a binding's provider setup goes in
///      front of the bootstrap payload, and this is that setup.
contract RoleReceiver is ReceiverBase {
    function initializeWith(
        address transmitter_,
        address gateway_,
        Call[] calldata calls
    ) external initializer {
        _grantGateway(gateway_);
        __ReceiverBase_init(transmitter_, calls);
    }
}

contract RoleTransmitter is TransmitterBase, OwnableUpgradeable {
    function initializeWith(address owner_, address transceiver_, address gateway_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, bytes32(0));
        _grantGateway(gateway_);
    }

    function _owner() internal view override returns (address) {
        return owner();
    }

    function _checkOwner() internal view override(TransmitterBase, OwnableUpgradeable) {
        OwnableUpgradeable._checkOwner();
    }

    /// @dev Stands in for what a binding's `_sendMessage` does before it calls out.
    function assertGateway(address a) external view {
        _checkRole(GATEWAY_ROLE, a);
    }
}

/// @dev The role graph on its own, with no messaging around it.
contract RoleHarness is Roles {
    function initialize(address treasury, address[] calldata gateways) external initializer {
        __Roles_init(treasury, gateways);
    }

    /// @dev Stands in for the gated entry point a transceiver exposes over `_revokeGateway`.
    ///      The harness leaves it ungated, because what is under test is the membership
    ///      bookkeeping rather than who may reach it.
    function revokeGateway(address gateway) external {
        _revokeGateway(gateway);
    }
}

/// @notice The two roles, and the shape of the answer.
///
/// @dev THE POINT OF ONE ROLE FOR BOTH DIRECTIONS is that a contract accepting deliveries from
///      one address while sending through another would be trusting two transports and
///      authenticating against one, and only a message from the second would ever reveal it.
///
/// @dev AND NEITHER ROLE IS AN AUTHORITY. `TREASURY` names where fees may go and `GATEWAY`
///      names which transports are real; neither can call anything, and neither can be
///      granted after the initializer that named it.
contract RolesTest is Test {
    address constant GATEWAY = address(0x6A7EAA7);
    address constant IMPOSTOR = address(0xBAD);
    address owner = address(0xA11CE);
    address msig = address(0x5165);

    RoleReceiver receiver;
    RoleTransmitter transmitter;

    bytes32 gatewayRole;
    bytes32 treasuryRole;

    function setUp() public {
        receiver = new RoleReceiver();
        receiver.initializeWith(address(0xB0B), GATEWAY, new Call[](0));

        transmitter = new RoleTransmitter();
        transmitter.initializeWith(owner, address(0xC0DE), GATEWAY);

        gatewayRole = receiver.GATEWAY_ROLE();
        treasuryRole = receiver.TREASURY_ROLE();
    }

    function _unauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, who, role
        );
    }

    /* ================================ both directions =============================== */

    /// @dev THE INBOUND HALF: one of the two checks standing in front of an `external` entry
    ///      point, and the reason the role sits on the receiver at all.
    function test_aReceiverRefusesADeliveryFromAnyoneElse() public {
        bytes memory sender = Erc7930.encodeEvm(1, address(0xB0B));
        bytes memory payload = Payload.encodeCalls(new Call[](0));

        vm.prank(IMPOSTOR);
        vm.expectRevert(_unauthorized(IMPOSTOR, gatewayRole));
        receiver.receiveMessage(bytes32(0), sender, payload);
    }

    /// @dev The sender is compared against `sourceTransmitter`, not the receiver's own address:
    ///      the two differ wherever CREATE2 does, and the stored fact is what is checked.
    function test_aReceiverAcceptsItsGrantedGateway() public {
        bytes memory sender = Erc7930.encodeEvm(1, address(0xB0B));
        bytes memory payload = Payload.encodeCalls(new Call[](0));

        vm.prank(GATEWAY);
        receiver.receiveMessage(bytes32(0), sender, payload);
    }

    /// @dev THE OUTBOUND HALF. The base cannot perform it for a binding, since only the
    ///      binding knows which address it is about to reach, but it reads the same role, so a
    ///      binding that checks before sending cannot drift from what its receiver enforces.
    function test_theOutboundHalfAsksTheSameRole() public {
        transmitter.assertGateway(GATEWAY);

        vm.expectRevert(_unauthorized(IMPOSTOR, gatewayRole));
        transmitter.assertGateway(IMPOSTOR);
    }

    function test_bothHalvesAgree() public view {
        assertTrue(receiver.hasRole(gatewayRole, GATEWAY));
        assertTrue(transmitter.hasRole(gatewayRole, GATEWAY));
        assertFalse(receiver.hasRole(gatewayRole, IMPOSTOR));
        assertFalse(transmitter.hasRole(gatewayRole, IMPOSTOR));
    }

    /// @dev EVERY SHIPPED LAYERZERO CONTRACT TRUSTS NOBODY, because no SDK is bound and so
    ///      nothing was granted. That is the honest default: a base that guessed an endpoint
    ///      address would be worse than one that accepts nothing, and it means the absence
    ///      fails loudly on the first message rather than quietly on a forged one.
    function testFuzz_theUnboundContractsTrustNobody(address anyone) public {
        LzReceiver r = new LzReceiver();
        LzTransmitter t = new LzTransmitter();
        assertFalse(r.hasRole(r.GATEWAY_ROLE(), anyone));
        assertFalse(t.hasRole(t.GATEWAY_ROLE(), anyone));
    }

    /* ========================== nothing can be granted ============================== */

    /// @dev AN ACCOUNT'S TRANSPORT IS FROZEN THE MOMENT IT IS ARMED, and not because a slot
    ///      refuses a second write: `GATEWAY` has no role admin, so it defaults to
    ///      `DEFAULT_ADMIN_ROLE`, which this protocol grants to nobody anywhere. There is no
    ///      caller a grant could come from. Not the transceiver that created it, not the msig,
    ///      not the account's own owner.
    function test_nothingCanAddAGatewayToAnAccount() public {
        assertEq(
            receiver.getRoleMemberCount(receiver.DEFAULT_ADMIN_ROLE()),
            0,
            "and nothing holds what administers it"
        );

        // Hoisted: an external call inside a pranked expression consumes the prank.
        bytes32 root = receiver.DEFAULT_ADMIN_ROLE();

        address[3] memory tryers = [receiver.parentTransceiver(), msig, address(0xB0B)];
        for (uint256 i; i < tryers.length; i++) {
            vm.prank(tryers[i]);
            vm.expectRevert(_unauthorized(tryers[i], root));
            receiver.grantRole(gatewayRole, IMPOSTOR);
        }
        assertFalse(receiver.hasRole(gatewayRole, IMPOSTOR));
    }

    /// @dev AN ACCOUNT NAMES NO TREASURY, because it collects no fees and has nothing to pay
    ///      out. The role exists on it and is empty, which is the same shape as `GATEWAY` on a
    ///      contract whose binding granted none.
    function test_anAccountHoldsNoTreasury() public view {
        assertEq(receiver.getRoleMemberCount(treasuryRole), 0);
        assertEq(transmitter.getRoleMemberCount(treasuryRole), 0);
    }

    /* ================================= the role graph =============================== */

    /// @dev NEITHER ROLE HAS AN ADMIN, WHICH IS WHAT SEALS BOTH. `__Roles_init` sets no role
    ///      admin, so each falls back to `DEFAULT_ADMIN_ROLE`, and that is granted to nobody
    ///      here or anywhere else in the protocol. The membership the initializer stated is
    ///      the membership for life.
    function test_neitherRoleHasAnAdmin() public {
        RoleHarness h = _harness();

        assertEq(h.getRoleAdmin(treasuryRole), h.DEFAULT_ADMIN_ROLE());
        assertEq(h.getRoleAdmin(gatewayRole), h.DEFAULT_ADMIN_ROLE());
        assertEq(h.getRoleMemberCount(h.DEFAULT_ADMIN_ROLE()), 0, "and nobody holds it");
    }

    /// @dev THE INITIALIZER IS THE ONLY MOMENT. A treasury and a set of gateways go in, and
    ///      afterwards no caller — not the one that deployed it, not a member of either role —
    ///      can add to either.
    function test_theInitializerIsTheOnlyGrantThatEverHappens() public {
        RoleHarness h = _harness();

        assertTrue(h.hasRole(treasuryRole, msig), "the treasury it was given");
        assertTrue(h.hasRole(gatewayRole, GATEWAY), "and the transport");

        bytes32 root = h.DEFAULT_ADMIN_ROLE();

        address[3] memory tryers = [address(this), msig, GATEWAY];
        for (uint256 i; i < tryers.length; i++) {
            vm.prank(tryers[i]);
            vm.expectRevert(_unauthorized(tryers[i], root));
            h.grantRole(gatewayRole, IMPOSTOR);

            vm.prank(tryers[i]);
            vm.expectRevert(_unauthorized(tryers[i], root));
            h.grantRole(treasuryRole, IMPOSTOR);
        }
    }

    /// @dev REVOKING SURVIVES, AND ONLY THROUGH AN ENTRY POINT A CONTRACT CHOOSES TO EXPOSE.
    ///      `_revokeGateway` is internal, so an account (which exposes nothing over it) cannot
    ///      lose its transport, while a transceiver's owner can drop a compromised one. The
    ///      public `revokeRole` remains unusable, since that is the path with no valid caller.
    function test_revokingIsInternalAndOneWay() public {
        RoleHarness h = _harness();

        bytes32 root = h.DEFAULT_ADMIN_ROLE();

        vm.prank(msig);
        vm.expectRevert(_unauthorized(msig, root));
        h.revokeRole(gatewayRole, GATEWAY);

        h.revokeGateway(GATEWAY);
        assertFalse(h.hasRole(gatewayRole, GATEWAY), "gone through the internal path");

        // And it cannot come back.
        vm.expectRevert(_unauthorized(address(this), root));
        h.grantRole(gatewayRole, GATEWAY);
    }

    /// @dev A ZERO IN EITHER POSITION IS SKIPPED RATHER THAN GRANTED. `address(0)` holding a
    ///      role would make `hasRole(role, address(0))` true, and the treasury check on
    ///      `withdrawFees` would then pass for the burn address.
    function test_zeroAddressesAreNeverMembers() public {
        RoleHarness h = new RoleHarness();
        address[] memory gateways = new address[](2);
        gateways[0] = address(0);
        gateways[1] = GATEWAY;
        h.initialize(address(0), gateways);

        assertFalse(h.hasRole(treasuryRole, address(0)));
        assertFalse(h.hasRole(gatewayRole, address(0)));
        assertEq(h.getRoleMemberCount(gatewayRole), 1, "only the real one");
    }

    function _harness() internal returns (RoleHarness h) {
        address[] memory gateways = new address[](1);
        gateways[0] = GATEWAY;

        h = new RoleHarness();
        h.initialize(msig, gateways);
    }

    /* ================================= enumeration ================================== */

    /// @dev THE SET IS WHAT AN OPERATOR ACTUALLY WANTS. A predicate answers only about an
    ///      address already suspected, so a deployment could carry a gateway nobody thought to
    ///      ask about; the member list makes it visible.
    function test_theMemberListSurvivesTheInitializerAndRevokes() public {
        address a = address(0xA);
        address b = address(0xB);
        address c = address(0xC);

        RoleHarness h = new RoleHarness();
        address[] memory gateways = new address[](4);
        gateways[0] = a;
        gateways[1] = b;
        gateways[2] = c;
        // A repeated entry changes nothing, so the list cannot hold a duplicate.
        gateways[3] = b;
        h.initialize(msig, gateways);
        assertEq(h.getRoleMemberCount(gatewayRole), 3);

        // Revoking from the MIDDLE is the case swap-and-pop gets wrong if the index bookkeeping
        // is off: the tail moves into the hole and must be findable there afterwards.
        h.revokeGateway(b);
        address[] memory left = h.getRoleMembers(gatewayRole);
        assertEq(left.length, 2);
        assertEq(left[0], a);
        assertEq(left[1], c, "the tail took the hole");
        assertFalse(h.hasRole(gatewayRole, b));

        // And the moved member is still revocable, which is what a stale index would break.
        h.revokeGateway(c);
        assertEq(h.getRoleMemberCount(gatewayRole), 1);
        assertEq(h.getRoleMember(gatewayRole, 0), a);

        // Revoking a non-member is a no-op rather than a pop of somebody else's entry.
        h.revokeGateway(b);
        assertEq(h.getRoleMemberCount(gatewayRole), 1);

        h.revokeGateway(a);
        assertEq(h.getRoleMemberCount(gatewayRole), 0);
    }

    /// @dev Announced, so a monitor can discover the enumeration rather than be told about it.
    function test_theEnumerableInterfaceIsAnnounced() public {
        RoleHarness h = _harness();
        assertTrue(h.supportsInterface(type(IAccessControlEnumerable).interfaceId));
        assertTrue(h.supportsInterface(type(IAccessControl).interfaceId));
    }

    /// @dev The role ids are namespaced, so an SDK that defines its own `TREASURY` cannot land
    ///      in the same member set through a string collision.
    function test_theRoleIdsAreNamespaced() public view {
        assertEq(treasuryRole, keccak256("crossecute.role.TREASURY"));
        assertEq(gatewayRole, keccak256("crossecute.role.GATEWAY"));
        assertTrue(treasuryRole != keccak256("TREASURY"));
        assertTrue(gatewayRole != keccak256("GATEWAY"));
    }
}
