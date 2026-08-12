// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";

import {CrossProxy, ICrossProxy} from "src/account/CrossProxy.sol";

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

/// @dev Stands in for the transceiver: deploys an account and hands it its logic.
contract Deployer {
    function deploy(bytes32 salt) external returns (address) {
        return Create2.deploy(0, salt, type(CrossProxy).creationCode);
    }

    function arm(address proxy, address impl, bytes calldata data) external {
        ICrossProxy(proxy).upgradeInitializeAndLock(impl, data);
    }
}

/// @notice The proxy that lets a transmitter and its receivers share one address.
contract CrossProxyTest is Test {
    Deployer deployer;
    bytes32 constant SALT = keccak256("account.1");

    function setUp() public {
        deployer = new Deployer();
    }

    function _adminOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.ADMIN_SLOT))));
    }

    /* ============================== the whole point ============================= */

    /// @dev THE PROPERTY THE PROXY EXISTS FOR. Same deployer, same salt, different logic:
    ///      one address. A minimal clone cannot do this: EIP-1167 embeds the
    ///      implementation in its initcode, so the two would land apart no matter what.
    function test_twoImplementationsShareOneAddress() public {
        // Two chains, modelled as two histories from the same state: one deployer address,
        // one salt, different logic installed in each.
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

    /// @dev The initcode hash is a constant with no implementation in it, which is the
    ///      mechanical reason the above holds.
    function test_theInitCodeHashIsIndependentOfTheImplementation() public view {
        bytes32 hash = keccak256(type(CrossProxy).creationCode);
        assertEq(
            Create2.computeAddress(SALT, hash, address(deployer)),
            Create2.computeAddress(SALT, hash, address(deployer))
        );
        // No constructor arguments at all: the creation code IS the initcode.
        assertEq(
            keccak256(type(CrossProxy).creationCode),
            keccak256(abi.encodePacked(type(CrossProxy).creationCode))
        );
    }

    /* ================================== the lock =============================== */

    /// @dev THERE IS NO STATE WITH A LIVE KEY AND A REAL IMPLEMENTATION. The single admin
    ///      operation upgrades, initializes, and retires the admin in that order. Not "the
    ///      deployer is expected to lock afterwards": it cannot do the first without the
    ///      last.
    function test_theKeyIsGoneBeforeTheTransactionEnds() public {
        address p = deployer.deploy(SALT);
        assertEq(_adminOf(p), address(deployer), "the deployer holds it while blank");

        deployer.arm(p, address(new LogicA()), abi.encodeCall(LogicA.initialize, (7)));

        assertEq(_adminOf(p), address(0), "and has given it up by the time logic exists");
        assertEq(LogicA(p).value(), 7);
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

    /// @dev Nobody else ever had it, including while the proxy is blank.
    ///
    /// @dev A BLANK PROXY DELEGATES TO THE ZERO ADDRESS, WHICH SUCCEEDS SILENTLY: a call
    ///      to an account with no code returns empty rather than reverting. So a stranger's
    ///      attempt is not refused, it is simply ignored: it changes nothing and installs
    ///      nothing. That is only tolerable because a blank proxy never survives the
    ///      transaction that created it; `SpokeTransceiverBase` deploys, arms, and locks in
    ///      one function, so there is no block in which one is observable.
    function test_aStrangerIsNeverTheAdmin() public {
        address p = deployer.deploy(SALT);
        address logic = address(new LogicA());

        vm.prank(address(0xBAD));
        ICrossProxy(p).upgradeInitializeAndLock(logic, "");

        assertEq(_adminOf(p), address(deployer), "the admin is unchanged");
        assertEq(
            StorageSlot.getAddressSlot(ERC1967Utils.IMPLEMENTATION_SLOT).value,
            address(0),
            "and nothing was installed"
        );
    }

    /// @dev AFTER THE LOCK THE ADMIN SELECTOR STOPS EXISTING, rather than reverting
    ///      forever. That is why the operation is routed inside `fallback` instead of
    ///      declared: a declared function would shadow that selector on the implementation
    ///      for the life of the account.
    function test_theAdminSelectorDelegatesAfterTheLock() public {
        address p = deployer.deploy(SALT);
        deployer.arm(p, address(new Shadower()), "");

        // The implementation's own function of the same name is reachable, which it could
        // not be if the proxy had declared one.
        assertEq(
            Shadower(p).upgradeInitializeAndLock(address(0), ""),
            "reached the implementation"
        );
    }

    /// @dev An unrecognised call from the admin reverts rather than delegating, so a
    ///      mistyped deployment step cannot silently become a call on a blank proxy.
    function test_anUnknownAdminCallIsRefused() public {
        address p = deployer.deploy(SALT);

        vm.prank(address(deployer));
        (bool ok, bytes memory ret) = p.call(abi.encodeWithSignature("nonsense()"));
        assertFalse(ok);
        assertEq(
            bytes4(ret),
            CrossProxy.UnknownAdminCall.selector,
            "named, not a bare delegate failure"
        );
    }

}

/// @dev An implementation that declares the same selector the proxy routes on, to prove
///      the proxy is not holding it hostage.
contract Shadower {
    function upgradeInitializeAndLock(address, bytes calldata)
        external
        pure
        returns (string memory)
    {
        return "reached the implementation";
    }
}
