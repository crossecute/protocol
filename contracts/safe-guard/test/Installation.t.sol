// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {PolicyEngine} from "policy-engine/core/PolicyEngine.sol";
import {SafePolicyGuard} from "policy-engine/SafePolicyGuard.sol";
import {IERC165} from "policy-engine/interfaces/IERC165.sol";
import {IPolicyEngine} from "policy-engine/interfaces/IPolicyEngine.sol";
import {ISafeModuleGuard} from "policy-engine/interfaces/ISafeModuleGuard.sol";
import {ISafeTransactionGuard} from "policy-engine/interfaces/ISafeTransactionGuard.sol";
import {Operation} from "policy-engine/interfaces/Operation.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {GuardDiscovery} from "../src/GuardDiscovery.sol";
import {ICrossecuteGuard} from "../src/ICrossecuteGuard.sol";
import {GuardTestBase} from "./GuardTestBase.sol";
import {TestTransmitter} from "./TestTransmitter.sol";

/// @dev Fresh and already-guarded Safes install through the same owner-approved batch.
contract InstallationTest is GuardTestBase {
    uint256 internal constant GUARD_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
    uint256 internal constant MODULE_GUARD_SLOT = 0xb104e0b93118902c651344349b610029d694cfdec91c589c91ebafbcd0289947;

    function test_installedGuardAdvertisesCrossecuteCapability() public {
        IERC165 installed = IERC165(GuardDiscovery.transactionGuard(address(safe)));
        SafePolicyGuard plain = new SafePolicyGuard(0, 1 days);
        assertTrue(installed.supportsInterface(type(ICrossecuteGuard).interfaceId));
        assertFalse(plain.supportsInterface(type(ICrossecuteGuard).interfaceId));
        assertTrue(installed.supportsInterface(type(IPolicyEngine).interfaceId));
        assertTrue(installed.supportsInterface(type(ISafeModuleGuard).interfaceId));
        assertTrue(installed.supportsInterface(type(ISafeTransactionGuard).interfaceId));
        assertTrue(installed.supportsInterface(type(IERC165).interfaceId));
        assertFalse(installed.supportsInterface(0xffffffff));
    }

    function test_freshSafe_transactionGuardOnly() public view {
        assertEq(_slot(safe, GUARD_SLOT), address(guard));
        assertEq(_slot(safe, MODULE_GUARD_SLOT), address(0));
    }

    function test_existingGuard_permitsBatch_installsAtomically() public {
        Safe guarded = _guardedByPrevious();
        _install(guarded, _signers(), guard, _defaultConfig(), true);
        assertEq(_slot(guarded, GUARD_SLOT), address(guard));
        assertEq(_slot(guarded, MODULE_GUARD_SLOT), address(guard));

        TestTransmitter guardedTransmitter = new TestTransmitter(address(guarded), sink);
        assertTrue(_exec(guarded, _signers(), address(guardedTransmitter), 0, _sendMessageData(), Enum.Operation.Call));
        assertEq(guardedTransmitter.sends(), 1);
    }

    /// @dev Safe 1.5.0 sends the installing transaction's post-hook to the guard it read beforehand.
    function test_existingGuard_receivesInstallingPostHook() public {
        Safe guarded = _guardedByPrevious();
        address previous = _slot(guarded, GUARD_SLOT);
        vm.expectCall(previous, abi.encodeWithSelector(ISafeTransactionGuard.checkAfterExecution.selector), 1);
        vm.expectCall(address(guard), abi.encodeWithSelector(ISafeTransactionGuard.checkAfterExecution.selector), 0);
        _install(guarded, _signers(), guard, _defaultConfig(), false);
    }

    function _guardedByPrevious() internal returns (Safe guarded) {
        guarded = _newEoaSafe();
        SafePolicyGuard previous = new SafePolicyGuard(0, 1 days);
        _install(guarded, _signers(), previous, _defaultConfig(), false);
        assertEq(_slot(guarded, GUARD_SLOT), address(previous));
    }

    function test_existingGuard_deniesBatch_nothingChanges() public {
        Safe guarded = _newEoaSafe();
        SafePolicyGuard previous = new SafePolicyGuard(0, 1 days);
        SafePolicyGuard.Configuration[] memory configs = new SafePolicyGuard.Configuration[](2);
        configs[0] = _config(address(0), bytes4(0), Operation.CALL, address(allowPolicy));
        // The previous guard's own installation batch, permitted once and then removed.
        configs[1] =
            _config(address(multiSend), multiSend.multiSend.selector, Operation.DELEGATECALL, address(allowPolicy));
        _install(guarded, _signers(), previous, configs, false);
        _removeDelegatecallPolicy(guarded, previous);

        vm.expectRevert(abi.encodeWithSelector(PolicyEngine.AccessDenied.selector, address(0)));
        this.installExternally(guarded);
        assertEq(_slot(guarded, GUARD_SLOT), address(previous));
    }

    function installExternally(Safe guarded) external {
        _install(guarded, _signers(), guard, _defaultConfig(), false);
    }

    /// @dev Removal is an owner self-call the policy must permit. The post-hook still reaches the
    ///      removed guard, which holds no record, and later sendMessage calls find no guard.
    function test_ownerRemoval_thenSendMessageFindsNoGuard() public {
        _exec(safe, _signers(), address(safe), 0, abi.encodeCall(safe.setGuard, (address(0))), Enum.Operation.Call);
        assertEq(_slot(safe, GUARD_SLOT), address(0));

        bytes memory sigs = _signFor(safe, _signers(), address(transmitter), 0, _sendMessageData(), Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(GuardDiscovery.NoGuard.selector, address(safe)));
        _execWith(safe, address(transmitter), 0, _sendMessageData(), Enum.Operation.Call, sigs);
    }

    function test_failedReplacement_keepsGuard() public {
        bytes memory data = abi.encodeCall(safe.setGuard, (address(new NotAGuard())));
        bytes memory sigs = _signFor(safe, _signers(), address(safe), 0, data, Enum.Operation.Call);
        vm.expectRevert(bytes("GS300"));
        _execWith(safe, address(safe), 0, data, Enum.Operation.Call, sigs);
        assertEq(_slot(safe, GUARD_SLOT), address(guard));
    }

    function test_configureImmediately_rejectedOnceInstalled() public {
        bytes memory data = abi.encodeCall(SafePolicyGuard.configureImmediately, (_defaultConfig()));
        bytes memory sigs = _signFor(safe, _signers(), address(guard), 0, data, Enum.Operation.Call);
        vm.expectRevert(PolicyEngine.GuardTargetDenied.selector);
        _execWith(safe, address(guard), 0, data, Enum.Operation.Call, sigs);
    }

    function test_sharedGuard_independentConfiguration() public {
        Safe narrow = _newEoaSafe();
        SafePolicyGuard.Configuration[] memory configs = new SafePolicyGuard.Configuration[](1);
        configs[0] =
            _config(address(multiSend), multiSend.multiSend.selector, Operation.DELEGATECALL, address(allowPolicy));
        _install(narrow, _signers(), guard, configs, false);
        TestTransmitter narrowTransmitter = new TestTransmitter(address(narrow), sink);

        bytes memory sigs =
            _signFor(narrow, _signers(), address(narrowTransmitter), 0, _sendMessageData(), Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(PolicyEngine.AccessDenied.selector, address(0)));
        _execWith(narrow, address(narrowTransmitter), 0, _sendMessageData(), Enum.Operation.Call, sigs);

        assertTrue(_exec(safe, _signers(), address(transmitter), 0, _sendMessageData(), Enum.Operation.Call));
    }

    function _removeDelegatecallPolicy(Safe guarded, SafePolicyGuard previous) internal {
        SafePolicyGuard.Configuration[] memory removal = new SafePolicyGuard.Configuration[](1);
        removal[0] = _config(address(multiSend), multiSend.multiSend.selector, Operation.DELEGATECALL, address(0));
        bytes32 root = keccak256(abi.encode(removal));
        _exec(
            guarded,
            _signers(),
            address(previous),
            0,
            abi.encodeCall(SafePolicyGuard.requestConfiguration, (root)),
            Enum.Operation.Call
        );
        _exec(
            guarded,
            _signers(),
            address(previous),
            0,
            abi.encodeCall(SafePolicyGuard.applyConfiguration, (removal)),
            Enum.Operation.Call
        );
    }

    function _slot(Safe safe_, uint256 slot) internal view returns (address) {
        return abi.decode(safe_.getStorageAt(slot, 1), (address));
    }
}

/// @dev Answers ERC-165 without supporting the transaction guard interface.
contract NotAGuard is IERC165 {
    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}
