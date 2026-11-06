// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";

import {LockedProxy, ILockedProxy} from "src/conduit/LockedProxy.sol";
import {LockedProxyInitCode} from "src/conduit/LockedProxyInitCode.sol";

/// @dev Two different implementations, to prove the address does not depend on which.
contract LogicA {
    uint256 public value;

    function initialize(uint256 v) external {
        value = v;
    }

    function which() external pure returns (string memory) {
        return "A";
    }
}

contract LogicB {
    uint256 public value;

    function initialize(uint256 v) external {
        value = v * 2;
    }

    function which() external pure returns (string memory) {
        return "B";
    }
}

/// @dev Counts every call it receives, so a test can tell a delegated call from one the proxy
///      handled itself.
contract Echo {
    uint256 public hits;

    fallback() external payable {
        ++hits;
    }

    receive() external payable {
        ++hits;
    }
}

contract Failing {
    function initialize() external pure {
        revert("init failed");
    }
}

/// @dev Calls back into the proxy, as its admin, from inside its own initializer.
contract Reenter {
    bool public reentrySucceeded;

    function initialize(address admin, address other) external {
        (reentrySucceeded,) = admin.call(abi.encodeCall(Deployer.arm, (address(this), other, "")));
    }
}

/// @dev Writes the slot an implementation must never write.
contract Clobber {
    function clobber() external {
        StorageSlot.getAddressSlot(ERC1967Utils.IMPLEMENTATION_SLOT).value = address(0);
    }
}

/// @dev Stands in for the transceiver: deploys a conduit and hands it its logic.
contract Deployer {
    function deploy(bytes32 salt) external returns (address) {
        return Create2.deploy(0, salt, type(LockedProxy).creationCode);
    }

    function arm(address proxy, address impl, bytes calldata data) external {
        ILockedProxy(proxy).upgradeInitializeAndLock(impl, data);
    }
}

/// @notice The proxy that lets a transmitter and its receivers share one address.
contract LockedProxyTest is Test {
    Deployer deployer;
    bytes32 constant SALT = keccak256("account.1");

    function setUp() public {
        deployer = new Deployer();
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function _armCall(address impl, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeCall(ILockedProxy.upgradeInitializeAndLock, (impl, data));
    }

    /// @dev The proxy is still blank and its deployer can still arm it.
    function _assertStillArmable(address p) internal {
        assertEq(_implOf(p), address(0), "blank");
        address impl = address(new LogicA());
        deployer.arm(p, impl, abi.encodeCall(LogicA.initialize, (3)));
        assertEq(_implOf(p), impl, "armed afterwards");
        assertEq(LogicA(p).value(), 3);
    }

    /* ============================== the whole point ============================= */

    /// @dev Same deployer, same salt, different logic: one address. An EIP-1167 clone embeds
    ///      the implementation in its initcode and could not do this.
    function test_twoImplementationsShareOneAddress() public {
        uint256 world = vm.snapshotState();

        address a = deployer.deploy(SALT);
        deployer.arm(a, address(new LogicA()), abi.encodeCall(LogicA.initialize, (21)));
        assertEq(LogicA(a).which(), "A");
        assertEq(LogicA(a).value(), 21);

        vm.revertToState(world);

        address b = deployer.deploy(SALT);
        deployer.arm(b, address(new LogicB()), abi.encodeCall(LogicB.initialize, (21)));
        assertEq(LogicB(b).which(), "B");
        assertEq(LogicB(b).value(), 42, "genuinely different logic");

        assertEq(a, b, "one address, whatever it was upgraded to");
    }

    /// @dev The admin is in the runtime code and not the initcode, so who deploys moves the
    ///      address only through the CREATE2 sender, as before. A proxy is therefore verified
    ///      by its address, not by a constant code hash.
    function test_theAddressIsPredictedFromTheInitCodeForEveryAdmin() public {
        bytes32 hash = keccak256(type(LockedProxy).creationCode);
        Deployer other = new Deployer();

        address p1 = deployer.deploy(SALT);
        address p2 = other.deploy(SALT);

        assertEq(p1, Create2.computeAddress(SALT, hash, address(deployer)));
        assertEq(p2, Create2.computeAddress(SALT, hash, address(other)));
        assertEq(p1.code.length, p2.code.length);
        assertTrue(p1.codehash != p2.codehash, "the admin is embedded in the runtime code");
    }

    /// @dev R8.3: every chain's build must derive the same conduits, and the transceiver now
    ///      computes the hash from its own build, so this is what catches a settings change.
    ///      Coverage builds unoptimized and is exempt.
    function test_theInitCodeHashIsPinned() public {
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) vm.skip(true);
        assertEq(
            keccak256(type(LockedProxy).creationCode),
            0x6d3833c585f8809561b488327140414769cdda10be277d5be13e08201693daa7
        );
    }

    /// @dev A transceiver deploys conduits from the stored copy, so it must be the initcode byte
    ///      for byte, whatever the call.
    function test_theStoredInitCodeIsTheInitCode() public {
        InitCodeStore store = new InitCodeStore();
        assertEq(store.load(), type(LockedProxy).creationCode);

        (bool ok, bytes memory data) =
            store.at().call(abi.encodeWithSignature("upgradeInitializeAndLock(address,bytes)", address(1), ""));
        assertTrue(ok);
        assertEq(data, type(LockedProxy).creationCode);
    }

    /// @dev A proxy owns no admin storage, so creating one costs no SSTORE and emits nothing.
    function test_theConstructorWritesNoStorageAndEmitsNothing() public {
        vm.recordLogs();
        address p = deployer.deploy(SALT);

        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(vm.load(p, ERC1967Utils.ADMIN_SLOT), bytes32(0));
        assertEq(vm.load(p, ERC1967Utils.IMPLEMENTATION_SLOT), bytes32(0));
    }

    /* ================================== the lock =============================== */

    /// @dev No state has a live key and real logic: installing the implementation is what ends
    ///      the deployer's ability to arm, so it cannot do the first without the last.
    function test_theArmPathClosesInTheArmingCall() public {
        address p = deployer.deploy(SALT);
        address impl = address(new LogicA());
        assertEq(_implOf(p), address(0), "blank while the deployer holds the key");

        deployer.arm(p, impl, abi.encodeCall(LogicA.initialize, (7)));

        assertEq(_implOf(p), impl);
        assertEq(LogicA(p).value(), 7);

        address logicB = address(new LogicB());
        vm.expectRevert();
        deployer.arm(p, logicB, "");
        assertEq(_implOf(p), impl, "unchanged");
    }

    function test_theDeployerCannotUpgradeAgain() public {
        address p = deployer.deploy(SALT);
        deployer.arm(p, address(new LogicA()), abi.encodeCall(LogicA.initialize, (7)));

        address logicB = address(new LogicB());
        bytes memory init = abi.encodeCall(LogicB.initialize, (7));

        // The call now delegates to the implementation, which has no such function.
        vm.expectRevert();
        deployer.arm(p, logicB, init);

        assertEq(LogicA(p).which(), "A", "still the original logic");
    }

    /// @dev A stranger's call on a blank proxy delegates to the zero address and succeeds
    ///      silently. It changes nothing, which is tolerable because a blank proxy never
    ///      survives the transaction that created it: `TransceiverBase` deploys and arms in
    ///      one function.
    function test_aStrangerIsNeverTheAdmin() public {
        address p = deployer.deploy(SALT);
        address logic = address(new LogicA());

        vm.prank(address(0xBAD));
        ILockedProxy(p).upgradeInitializeAndLock(logic, "");

        _assertStillArmable(p);
    }

    /// @dev The admin is whoever created the proxy, not whoever started the transaction.
    function test_theTransactionOriginIsNotTheAdmin() public {
        address p = deployer.deploy(SALT);
        address logicA = address(new LogicA());
        address logicB = address(new LogicB());

        vm.prank(address(0xA11CE), address(0xA11CE));
        ILockedProxy(p).upgradeInitializeAndLock(logicA, "");
        assertEq(_implOf(p), address(0), "its origin armed nothing");

        vm.prank(address(deployer), address(0xA11CE));
        (bool ok,) = p.call(_armCall(logicB, ""));

        assertTrue(ok, "the creator arms it whoever the origin is");
        assertEq(LogicB(p).which(), "B");
    }

    function testFuzz_aStrangerCannotArmABlankProxy(address caller, address impl, bytes calldata init) public {
        vm.assume(caller != address(deployer) && caller != address(vm));
        address p = deployer.deploy(SALT);
        vm.assume(caller != p);

        vm.prank(caller, caller);
        (bool ok,) = p.call(_armCall(impl, init));

        assertTrue(ok, "ignored, not refused");
        _assertStillArmable(p);
    }

    /// @dev After the lock the admin selector stops existing, rather than reverting forever,
    ///      for the deployer as for anyone. The operation is routed inside `fallback` instead
    ///      of declared so that it never shadows that selector on an implementation.
    function test_theAdminSelectorDelegatesAfterTheLock() public {
        address p = deployer.deploy(SALT);
        deployer.arm(p, address(new Shadower()), "");

        assertEq(Shadower(p).upgradeInitializeAndLock(address(0), ""), "reached the implementation");

        vm.prank(address(deployer));
        assertEq(Shadower(p).upgradeInitializeAndLock(address(0), ""), "reached the implementation", "as the admin");
    }

    /// @dev An unrecognised call from the admin reverts rather than delegating, so a mistyped
    ///      deployment step cannot silently become a call on a blank proxy.
    function test_anUnknownAdminCallIsRefused() public {
        address p = deployer.deploy(SALT);

        vm.prank(address(deployer));
        (bool ok, bytes memory ret) = p.call(abi.encodeWithSignature("nonsense()"));

        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(LockedProxy.UnknownAdminCall.selector, bytes4(keccak256("nonsense()"))));
        _assertStillArmable(p);
    }

    /// @dev Calldata shorter than a selector, and none at all, are unknown calls too: an
    ///      ether transfer from the admin to a blank proxy reverts.
    function test_anAdminCallWithNoSelectorIsRefused() public {
        address p = deployer.deploy(SALT);

        vm.prank(address(deployer));
        (bool ok, bytes memory ret) = p.call(hex"abcd");
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(LockedProxy.UnknownAdminCall.selector, bytes4(0xabcd0000)));

        vm.deal(address(deployer), 1 wei);
        vm.prank(address(deployer));
        (ok, ret) = p.call{value: 1 wei}("");
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(LockedProxy.UnknownAdminCall.selector, bytes4(0)));

        _assertStillArmable(p);
        assertEq(p.balance, 0);
    }

    /// @dev Every way the arming call can fail leaves a blank proxy that the deployer can arm.
    function test_anImplementationWithNoCodeIsRefused() public {
        address p = deployer.deploy(SALT);

        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, address(0)));
        deployer.arm(p, address(0), "");

        address eoa = address(0xE0A);
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, eoa));
        deployer.arm(p, eoa, "");

        _assertStillArmable(p);
    }

    function test_aMalformedArmCallIsRefused() public {
        address p = deployer.deploy(SALT);

        vm.prank(address(deployer));
        (bool ok,) = p.call(abi.encodePacked(ILockedProxy.upgradeInitializeAndLock.selector, uint256(1)));

        assertFalse(ok);
        _assertStillArmable(p);
    }

    function test_aFailingInitializerLeavesTheProxyBlank() public {
        address p = deployer.deploy(SALT);
        address failing = address(new Failing());

        vm.expectRevert("init failed");
        deployer.arm(p, failing, abi.encodeCall(Failing.initialize, ()));

        _assertStillArmable(p);
    }

    /// @dev Value sent with an arming call reaches the initializer, as in a plain upgrade, and
    ///      is refused when there is no initializer to receive it.
    function test_armingValueNeedsAnInitializer() public {
        address p = deployer.deploy(SALT);
        address echo = address(new Echo());
        vm.deal(address(deployer), 2 wei);

        vm.prank(address(deployer));
        (bool ok, bytes memory ret) = p.call{value: 1 wei}(_armCall(echo, ""));
        assertFalse(ok);
        assertEq(bytes4(ret), ERC1967Utils.ERC1967NonPayable.selector);
        assertEq(_implOf(p), address(0));

        vm.prank(address(deployer));
        (ok,) = p.call{value: 1 wei}(_armCall(echo, hex"01"));
        assertTrue(ok);
        assertEq(p.balance, 1 wei);
        assertEq(Echo(payable(p)).hits(), 1, "the initializer ran as the proxy");
    }

    function test_armingEmitsUpgradedThenLocked() public {
        address p = deployer.deploy(SALT);
        address impl = address(new LogicA());

        vm.expectEmit(true, false, false, false, p);
        emit IERC1967.Upgraded(impl);
        vm.expectEmit(false, false, false, true, p);
        emit LockedProxy.Locked(impl);
        deployer.arm(p, impl, "");
    }

    /// @dev The implementation is installed before its initializer runs, so a callback into
    ///      the proxy from inside the initializer is an ordinary call and cannot arm it again.
    function test_theInitializerCannotArmTheProxyAgain() public {
        address p = deployer.deploy(SALT);
        address impl = address(new Reenter());
        address other = address(new LogicB());

        deployer.arm(p, impl, abi.encodeCall(Reenter.initialize, (address(deployer), other)));

        assertEq(_implOf(p), impl, "still the first implementation");
        assertFalse(Reenter(p).reentrySucceeded(), "the callback was refused");
    }

    function testFuzz_afterTheLockNoCallerChangesTheImplementation(
        bool asAdmin,
        address caller,
        bytes calldata data,
        uint96 value
    ) public {
        vm.assume(bytes4(data) != bytes4(keccak256("hits()")));
        address impl = address(new Echo());
        address p = deployer.deploy(SALT);
        deployer.arm(p, impl, "");
        if (asAdmin) caller = address(deployer);
        vm.assume(caller != address(vm) && caller != p);

        vm.deal(caller, value);
        vm.prank(caller);
        (bool ok,) = p.call{value: value}(data);

        assertTrue(ok);
        assertEq(Echo(payable(p)).hits(), 1, "every call reached the implementation");
        assertEq(_implOf(p), impl);
    }

    /// @dev The lock is the implementation slot, so an implementation that clears it hands
    ///      arming back to the deployer. An implementation must not write ERC-1967 slots; a
    ///      lock held in any slot rests on that, and the deployer's code never arms a proxy
    ///      that has code (`Conduits.requireVacant`, `Create2.deploy`).
    function test_anImplementationThatClearsTheSlotReopensArmingToTheDeployer() public {
        address p = deployer.deploy(SALT);
        deployer.arm(p, address(new Clobber()), "");

        Clobber(p).clobber();
        assertEq(_implOf(p), address(0));

        deployer.arm(p, address(new LogicA()), "");
        assertEq(LogicA(p).which(), "A");
    }
}

/// @dev An implementation that declares the same selector the proxy routes on, to prove
///      the proxy is not holding it hostage.
contract Shadower {
    function upgradeInitializeAndLock(address, bytes calldata) external pure returns (string memory) {
        return "reached the implementation";
    }
}

/// @dev `LockedProxyInitCode` as a transceiver implementation uses it.
contract InitCodeStore {
    address public immutable at;

    constructor() {
        at = LockedProxyInitCode.store();
    }

    function load() external view returns (bytes memory) {
        return LockedProxyInitCode.load(at);
    }
}
