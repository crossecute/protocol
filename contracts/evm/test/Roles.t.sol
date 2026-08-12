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

/// @dev An account names its transport in the call that arms it, which is the only moment it
///      can: it holds no `ADMIN`, so nothing may grant one afterwards. Granting ahead of
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
    function initialize(address admin) external initializer {
        __Roles_init(admin);
    }
}

/// @notice The two authorities, and the shape of the answer.
///
/// @dev THE POINT OF ONE ROLE FOR BOTH DIRECTIONS is that a contract accepting deliveries from
///      one address while sending through another would be trusting two transports and
///      authenticating against one, and only a message from the second would ever reveal it.
contract RolesTest is Test {
    address constant GATEWAY = address(0x6A7EAA7);
    address constant IMPOSTOR = address(0xBAD);
    address owner = address(0xA11CE);
    address msig = address(0x5165);

    RoleReceiver receiver;
    RoleTransmitter transmitter;

    bytes32 gatewayRole;
    bytes32 adminRole;

    function setUp() public {
        receiver = new RoleReceiver();
        receiver.initializeWith(address(0xB0B), GATEWAY, new Call[](0));

        transmitter = new RoleTransmitter();
        transmitter.initializeWith(owner, address(0xC0DE), GATEWAY);

        gatewayRole = receiver.GATEWAY_ROLE();
        adminRole = receiver.ADMIN_ROLE();
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

    /* ============================ an account has no admin =========================== */

    /// @dev AN ACCOUNT'S TRANSPORT IS FROZEN THE MOMENT IT IS ARMED, and not because a slot
    ///      refuses a second write: `GATEWAY` is administered by `ADMIN`, and an account holds
    ///      none, so there is nobody a grant could come from. Not the transceiver that created
    ///      it, not the msig, not the account's own owner.
    function test_nothingCanAddAGatewayToAnAccount() public {
        assertEq(receiver.getRoleMemberCount(adminRole), 0, "an account has no admin");

        address[3] memory tryers = [receiver.parentTransceiver(), msig, address(0xB0B)];
        for (uint256 i; i < tryers.length; i++) {
            vm.prank(tryers[i]);
            vm.expectRevert(_unauthorized(tryers[i], adminRole));
            receiver.grantRole(gatewayRole, IMPOSTOR);
        }
        assertFalse(receiver.hasRole(gatewayRole, IMPOSTOR));
    }

    /* ================================= the role graph =============================== */

    /// @dev `DEFAULT_ADMIN_ROLE` IS LEFT UNHELD ON PURPOSE. OZ's default puts it over every
    ///      role, which would make "who may add a gateway" a question with two answers.
    function test_nothingSitsAboveAdmin() public {
        RoleHarness h = new RoleHarness();
        h.initialize(msig);

        assertEq(h.getRoleAdmin(adminRole), adminRole, "ADMIN administers itself");
        assertEq(h.getRoleAdmin(gatewayRole), adminRole, "and GATEWAY");
        assertEq(h.getRoleMemberCount(h.DEFAULT_ADMIN_ROLE()), 0);

        // So the address OZ would normally have made omnipotent has no power here.
        vm.prank(IMPOSTOR);
        vm.expectRevert(_unauthorized(IMPOSTOR, adminRole));
        h.grantRole(gatewayRole, IMPOSTOR);
    }

    function test_theAdminMovesTheGatewaySetAndItsOwn() public {
        RoleHarness h = new RoleHarness();
        h.initialize(msig);

        vm.prank(msig);
        h.grantRole(gatewayRole, GATEWAY);
        assertTrue(h.hasRole(gatewayRole, GATEWAY));

        // Handover: an admin may grant its own role, which is the equivalent of what
        // `transferOwnership` used to be, and revoking the old one completes it.
        vm.prank(msig);
        h.grantRole(adminRole, owner);
        vm.prank(owner);
        h.revokeRole(adminRole, msig);

        assertEq(h.getRoleMembers(adminRole).length, 1);
        assertEq(h.getRoleMember(adminRole, 0), owner);
    }

    /* ================================= enumeration ================================== */

    /// @dev THE SET IS WHAT AN OPERATOR ACTUALLY WANTS. A predicate answers only about an
    ///      address already suspected, so a deployment could carry a gateway nobody thought to
    ///      ask about; the member list makes it visible.
    function test_theMemberListSurvivesGrantsAndRevokes() public {
        RoleHarness h = new RoleHarness();
        h.initialize(msig);
        address a = address(0xA);
        address b = address(0xB);
        address c = address(0xC);

        vm.startPrank(msig);
        h.grantRole(gatewayRole, a);
        h.grantRole(gatewayRole, b);
        h.grantRole(gatewayRole, c);

        // A repeated grant changes nothing, so the list cannot hold a duplicate.
        h.grantRole(gatewayRole, b);
        assertEq(h.getRoleMemberCount(gatewayRole), 3);

        // Revoking from the MIDDLE is the case swap-and-pop gets wrong if the index bookkeeping
        // is off: the tail moves into the hole and must be findable there afterwards.
        h.revokeRole(gatewayRole, b);
        address[] memory left = h.getRoleMembers(gatewayRole);
        assertEq(left.length, 2);
        assertEq(left[0], a);
        assertEq(left[1], c, "the tail took the hole");
        assertFalse(h.hasRole(gatewayRole, b));

        // And the moved member is still revocable, which is what a stale index would break.
        h.revokeRole(gatewayRole, c);
        assertEq(h.getRoleMemberCount(gatewayRole), 1);
        assertEq(h.getRoleMember(gatewayRole, 0), a);

        // Revoking a non-member is a no-op rather than a pop of somebody else's entry.
        h.revokeRole(gatewayRole, b);
        assertEq(h.getRoleMemberCount(gatewayRole), 1);

        h.revokeRole(gatewayRole, a);
        assertEq(h.getRoleMemberCount(gatewayRole), 0);
        vm.stopPrank();
    }

    /// @dev Announced, so a monitor can discover the enumeration rather than be told about it.
    function test_theEnumerableInterfaceIsAnnounced() public {
        RoleHarness h = new RoleHarness();
        h.initialize(msig);
        assertTrue(h.supportsInterface(type(IAccessControlEnumerable).interfaceId));
        assertTrue(h.supportsInterface(type(IAccessControl).interfaceId));
    }

    /// @dev The role ids are namespaced, so an SDK that defines its own `ADMIN` cannot land in
    ///      the same member set through a string collision.
    function test_theRoleIdsAreNamespaced() public view {
        assertEq(adminRole, keccak256("crossecute.role.ADMIN"));
        assertEq(gatewayRole, keccak256("crossecute.role.GATEWAY"));
        assertTrue(adminRole != keccak256("ADMIN"));
        assertTrue(gatewayRole != keccak256("GATEWAY"));
    }
}
