// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {PolicyEngine} from "policy-engine/core/PolicyEngine.sol";
import {SafePolicyGuard} from "policy-engine/SafePolicyGuard.sol";
import {IPolicy} from "policy-engine/interfaces/IPolicy.sol";
import {IPolicyEngine} from "policy-engine/interfaces/IPolicyEngine.sol";
import {Operation} from "policy-engine/interfaces/Operation.sol";
import {AccessSelector} from "policy-engine/libraries/AccessSelector.sol";
import {AllowedModulePolicy} from "policy-engine/policies/AllowedModulePolicy.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {ICrossecuteGuard} from "../src/ICrossecuteGuard.sol";
import {GuardTestBase} from "./GuardTestBase.sol";
import {Collider, Sink, TestTransmitter} from "./TestTransmitter.sol";

/// @dev Permits owner transactions only.
contract OwnerOnlyPolicy is IPolicy {
    error ModuleDenied();

    function checkTransaction(
        address,
        address,
        uint256,
        bytes calldata,
        Operation,
        address module,
        bytes calldata,
        AccessSelector.T
    ) external pure returns (bytes4) {
        require(module == address(0), ModuleDenied());
        return IPolicy.checkTransaction.selector;
    }

    function configure(address, AccessSelector.T, bytes memory) external pure returns (bool) {
        return true;
    }
}

/// @dev During a check, tries to drive a check for a different Safe.
contract CrossSafePolicy is IPolicy {
    address public immutable OTHER;

    constructor(address other) {
        OTHER = other;
    }

    function checkTransaction(
        address,
        address to,
        uint256 value,
        bytes calldata data,
        Operation op,
        address,
        bytes calldata,
        AccessSelector.T
    ) external returns (bytes4) {
        IPolicyEngine(msg.sender).checkTransaction(OTHER, to, value, data, op, "");
        return IPolicy.checkTransaction.selector;
    }

    function configure(address, AccessSelector.T, bytes memory) external pure returns (bool) {
        return true;
    }
}

contract Module {
    function exec(Safe safe, address to, bytes calldata data, Enum.Operation op) external returns (bool) {
        return safe.execTransactionFromModule(to, 0, data, op);
    }

    /// @dev Bubbles the inner revert instead of reporting `false`.
    function execStrict(Safe safe, address to, bytes calldata data, Enum.Operation op) external {
        (bool success, bytes memory result) = safe.execTransactionFromModuleReturnData(to, 0, data, op);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}

/// @dev The guard in both slots, with a policy that has no fallback: owner self-calls go through
///      `OwnerOnlyPolicy`, the module may call the sink, and nothing else is configured.
contract ModuleTest is GuardTestBase {
    Module internal module;
    Safe internal guarded;
    TestTransmitter internal guardedTransmitter;
    Collider internal collider;
    OwnerOnlyPolicy internal ownerOnly;
    AllowedModulePolicy internal modulePolicy;

    function setUp() public override {
        super.setUp();
        module = new Module();
        collider = new Collider();
        ownerOnly = new OwnerOnlyPolicy();
        modulePolicy = new AllowedModulePolicy();
        guarded = _newEoaSafe();
        guardedTransmitter = new TestTransmitter(address(guarded), sink);

        SafePolicyGuard.Configuration[] memory configs = new SafePolicyGuard.Configuration[](6);
        configs[0] = _config(address(guarded), guarded.enableModule.selector, Operation.CALL, address(ownerOnly));
        configs[1] = _config(address(guarded), guarded.setGuard.selector, Operation.CALL, address(ownerOnly));
        configs[2] = _config(
            address(guardedTransmitter), TestTransmitter.sendMessage.selector, Operation.CALL, address(allowPolicy)
        );
        configs[3] = _config(address(collider), Collider.sendMessage.selector, Operation.CALL, address(allowPolicy));
        configs[4] = SafePolicyGuard.Configuration(
            address(sink), Sink.hit.selector, Operation.CALL, address(modulePolicy), abi.encode(address(module), true)
        );
        configs[5] =
            _config(address(multiSend), multiSend.multiSend.selector, Operation.DELEGATECALL, address(ownerOnly));
        _install(guarded, _signers(), guard, configs, true);
        _exec(
            guarded,
            _signers(),
            address(guarded),
            0,
            abi.encodeCall(guarded.enableModule, (address(module))),
            Enum.Operation.Call
        );
    }

    function test_bothSlotsHoldTheGuard() public view {
        assertEq(_slot(guarded, 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8), address(guard));
        assertEq(_slot(guarded, 0xb104e0b93118902c651344349b610029d694cfdec91c589c91ebafbcd0289947), address(guard));
    }

    function test_moduleDispatch_rejectedOnPermittedTarget() public {
        vm.expectRevert(ICrossecuteGuard.ModuleSendMessageDenied.selector);
        module.exec(guarded, address(guardedTransmitter), _dispatchData(), Enum.Operation.Call);

        vm.expectRevert(ICrossecuteGuard.ModuleSendMessageDenied.selector);
        module.exec(guarded, address(collider), _dispatchData(), Enum.Operation.Call);
    }

    function test_modulePermittedCall_succeeds() public {
        bytes memory data = abi.encodeCall(Sink.hit, (guard, address(guarded)));
        assertTrue(module.exec(guarded, address(sink), data, Enum.Operation.Call));
        assertEq(sink.calls(), 1);
    }

    function test_moduleSelfCalls_denied() public {
        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeCall(guarded.setGuard, (address(0)));
        calls[1] = abi.encodeCall(guarded.setModuleGuard, (address(0)));
        calls[2] = abi.encodeCall(guarded.addOwnerWithThreshold, (address(0xBAD), 1));
        calls[3] = abi.encodeCall(guarded.changeThreshold, (1));
        calls[4] = abi.encodeCall(guarded.setFallbackHandler, (address(0)));
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.expectPartialRevert(i == 0 ? PolicyEngine.PolicyReverted.selector : PolicyEngine.AccessDenied.selector);
            module.exec(guarded, address(guarded), calls[i], Enum.Operation.Call);
        }
    }

    function test_moduleDelegatecall_denied() public {
        vm.expectPartialRevert(PolicyEngine.PolicyReverted.selector);
        module.exec(guarded, address(multiSend), abi.encodeCall(multiSend.multiSend, ("")), Enum.Operation.DelegateCall);
    }

    function test_moduleGuardConfiguration_denied() public {
        bytes memory data = abi.encodeCall(SafePolicyGuard.requestConfiguration, (bytes32(uint256(1))));
        vm.expectRevert(PolicyEngine.ModuleConfigurationDenied.selector);
        module.exec(guarded, address(guard), data, Enum.Operation.Call);
    }

    function test_ownerDispatch_stillWorks() public {
        assertTrue(_exec(guarded, _signers(), address(guardedTransmitter), 0, _dispatchData(), Enum.Operation.Call));
        assertEq(guardedTransmitter.sends(), 1);
    }

    /// @dev With the module guard slot empty the module is trusted with its Safe permissions. Its
    ///      dispatch never enters the owner hook, so the transmitter finds nothing to consume.
    function test_withoutModuleGuard_moduleDispatchFindsNoRecord() public {
        _exec(
            safe,
            _signers(),
            address(safe),
            0,
            abi.encodeCall(safe.enableModule, (address(module))),
            Enum.Operation.Call
        );
        // `execTransactionFromModule` reports the inner NoLiveDispatch revert as `false`.
        vm.expectCall(address(guard), abi.encodeCall(ICrossecuteGuard.consume, (address(safe))));
        assertFalse(module.exec(safe, address(transmitter), _dispatchData(), Enum.Operation.Call));
        assertEq(transmitter.sends(), 0);
    }

    function test_crossSafePolicyCheck_rejected() public {
        Safe checked = _newEoaSafe();
        SafePolicyGuard.Configuration[] memory configs = new SafePolicyGuard.Configuration[](2);
        configs[0] = _config(address(0), bytes4(0), Operation.CALL, address(new CrossSafePolicy(address(safe))));
        configs[1] =
            _config(address(multiSend), multiSend.multiSend.selector, Operation.DELEGATECALL, address(allowPolicy));
        _install(checked, _signers(), guard, configs, false);
        bytes memory sigs = _signFor(checked, _signers(), address(0xBEEF), 0, "", Enum.Operation.Call);
        vm.expectPartialRevert(PolicyEngine.PolicyReverted.selector);
        _execWith(checked, address(0xBEEF), 0, "", Enum.Operation.Call, sigs);
    }

    /// @dev A Safe called from another Safe's execution is checked against its own policy.
    function test_crossSafeExecution_usesCalleePolicy() public {
        bytes memory sigs = _signFor(guarded, _signers(), address(0xBEEF), 0, "", Enum.Operation.Call);
        bytes memory nested = abi.encodeCall(
            Safe.execTransaction,
            (address(0xBEEF), 0, "", Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), sigs)
        );
        transmitter.setMode(TestTransmitter.Mode.ConsumeThenCall, address(guarded), nested);
        bytes memory outer = _signFor(safe, _signers(), address(transmitter), 0, _dispatchData(), Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(PolicyEngine.AccessDenied.selector, address(0)));
        _execWith(safe, address(transmitter), 0, _dispatchData(), Enum.Operation.Call, outer);
    }

    function _slot(Safe safe_, uint256 slot) internal view returns (address) {
        return abi.decode(safe_.getStorageAt(slot, 1), (address));
    }
}
