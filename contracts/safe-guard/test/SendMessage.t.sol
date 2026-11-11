// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {IERC7786GatewaySource} from "crossecute/messaging/IErc7786.sol";
import {PolicyEngine} from "policy-engine/core/PolicyEngine.sol";
import {SafePolicyGuard} from "policy-engine/SafePolicyGuard.sol";
import {IPolicy} from "policy-engine/interfaces/IPolicy.sol";
import {ISafeTransactionGuard} from "policy-engine/interfaces/ISafeTransactionGuard.sol";
import {Operation} from "policy-engine/interfaces/Operation.sol";
import {AccessSelector} from "policy-engine/libraries/AccessSelector.sol";
import {AllowPolicy} from "policy-engine/policies/AllowPolicy.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {GuardDiscovery} from "../src/GuardDiscovery.sol";
import {ICrossecuteGuard, SafeTx, SignedSafeTx} from "../src/ICrossecuteGuard.sol";
import {SafeHashes} from "../src/SafeHashes.sol";
import {Batch} from "./Batch.sol";
import {CrossecuteGuardHarness} from "./CrossecuteGuardHarness.sol";
import {GuardTestBase} from "./GuardTestBase.sol";
import {Module} from "./Module.t.sol";
import {Collider, TestTransmitter, Thief} from "./TestTransmitter.sol";

/// @dev Owner execution through a real Safe: staging, consumption, cleanup and nesting.
///      `BootstrapTest` reruns these tests with `bootstrap` calldata.
contract SendMessageTest is GuardTestBase {
    function test_transmitterUsesProtocolSelector() public pure {
        assertEq(TestTransmitter.sendMessage.selector, IERC7786GatewaySource.sendMessage.selector);
    }

    function test_sendMessage_consumedBeforeEffectsAndCleared() public {
        bytes memory data = _stagedData();
        bytes32 txHash = _txHash(safe, address(transmitter), 1 ether, data, Enum.Operation.Call);
        bytes memory signatures = _sign(_signers(), txHash);

        _run(
            _execCallWith(safe, address(transmitter), 1 ether, data, Enum.Operation.Call, signatures),
            _cleared(safe, _words(signatures))
        );

        assertEq(transmitter.lastSafeTxHash(), txHash);
        assertEq(transmitter.lastSignatures(), signatures);
        assertEq(transmitter.lastValue(), 1 ether);
        assertEq(sink.calls(), 1);
        assertTrue(sink.consumedFirst());
        assertEq(address(sink).balance, 1 ether);
    }

    /// @dev Every payment field is distinct and nonzero, so a swapped or dropped field fails.
    function test_sendMessage_returnsEverySignedField() public {
        bytes memory data = _stagedData();
        uint256 nonce = safe.nonce();
        Payment memory payment = Payment(7777, address(0xCAFE), payable(address(0xF00D)));
        (bytes32 txHash, bytes memory signatures) =
            _execPaid(safe, _signers(), address(transmitter), 2, data, Enum.Operation.Call, payment);

        SignedSafeTx memory signedSafeTx = abi.decode(transmitter.lastSendMessage(), (SignedSafeTx));
        SafeTx memory safeTx = signedSafeTx.safeTx;
        assertEq(safeTx.to, address(transmitter));
        assertEq(safeTx.value, 2);
        assertEq(safeTx.data.length, 0);
        assertEq(safeTx.operation, uint8(Enum.Operation.Call));
        assertEq(safeTx.safeTxGas, 0);
        assertEq(safeTx.baseGas, 7777);
        assertEq(safeTx.gasPrice, 0);
        assertEq(safeTx.gasToken, address(0xCAFE));
        assertEq(safeTx.refundReceiver, address(0xF00D));
        assertEq(safeTx.nonce, nonce);
        assertEq(signedSafeTx.signatures, signatures);
        // What a consumer does: the Safe called it with the signed calldata.
        safeTx.data = data;
        assertEq(
            safe.getTransactionHash(
                safeTx.to,
                safeTx.value,
                safeTx.data,
                Enum.Operation(safeTx.operation),
                safeTx.safeTxGas,
                safeTx.baseGas,
                safeTx.gasPrice,
                safeTx.gasToken,
                payable(safeTx.refundReceiver),
                safeTx.nonce
            ),
            txHash
        );
    }

    function test_sendMessage_preservesNestedOwnerAndPolicyContext() public {
        (Safe parent, Safe child) = _nestedParent();
        TestTransmitter parentTransmitter = new TestTransmitter(address(parent), sink);
        bytes memory data = _stagedData();
        bytes32 txHash = _txHash(parent, address(parentTransmitter), 0, data, Enum.Operation.Call);
        bytes memory signatures = _withPolicyContext(_sign(_nestedSigners(child), txHash), hex"c0ffee");

        _run(
            _execCallWith(parent, address(parentTransmitter), 0, data, Enum.Operation.Call, signatures),
            _cleared(parent, _words(signatures))
        );
        assertEq(parentTransmitter.lastSignatures(), signatures);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_sendMessage_roundtripsAnyLength(uint256 length, uint256 seed) public {
        length = bound(length, 0, 4096);
        bytes memory context = new bytes(length);
        for (uint256 i = 0; i < length; ++i) {
            context[i] = bytes1(uint8(uint256(keccak256(abi.encode(seed, i)))));
        }
        bytes memory data = _stagedData();
        bytes memory signatures = _withPolicyContext(
            _sign(_signers(), _txHash(safe, address(transmitter), 0, data, Enum.Operation.Call)), context
        );

        _run(
            _execCallWith(safe, address(transmitter), 0, data, Enum.Operation.Call, signatures),
            _cleared(safe, _words(signatures))
        );
        assertEq(transmitter.lastSignatures(), signatures);
    }

    function test_sendMessage_noByteCap() public {
        bytes memory data = _stagedData();
        bytes memory signatures = _withPolicyContext(
            _sign(_signers(), _txHash(safe, address(transmitter), 0, data, Enum.Operation.Call)), new bytes(20_001)
        );
        _execWith(safe, address(transmitter), 0, data, Enum.Operation.Call, signatures);
        assertEq(transmitter.lastSignatures(), signatures);
    }

    function test_longThenShortBlob_leavesNoTail() public {
        Collider collider = new Collider();
        bytes memory data = _stagedData();
        uint256 nonce = safe.nonce();
        bytes memory long = _withPolicyContext(
            _sign(_signers(), _txHashAt(safe, address(collider), 0, data, Enum.Operation.Call, nonce)), new bytes(1000)
        );
        bytes memory short =
            _sign(_signers(), _txHashAt(safe, address(transmitter), 0, data, Enum.Operation.Call, nonce + 1));

        _run(
            _execCallWith(safe, address(collider), 0, data, Enum.Operation.Call, long),
            _execCallWith(safe, address(transmitter), 0, data, Enum.Operation.Call, short),
            _cleared(safe, _words(long))
        );
        assertEq(transmitter.lastSignatures(), short);
    }

    function test_consume_wrongTarget() public {
        Thief thief = new Thief();
        transmitter.setMode(
            TestTransmitter.Mode.CallThenConsume, address(thief), abi.encodeCall(Thief.steal, (guard, address(safe)))
        );
        bytes memory sigs = _signFor(safe, _signers(), address(transmitter), 0, _stagedData(), Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.NotSignedTarget.selector, address(thief)));
        _execWith(safe, address(transmitter), 0, _stagedData(), Enum.Operation.Call, sigs);
    }

    function test_consume_wrongSafe() public {
        Safe other = _newEoaSafe();
        Thief thief = new Thief();
        transmitter.setMode(
            TestTransmitter.Mode.CallThenConsume, address(thief), abi.encodeCall(Thief.steal, (guard, address(other)))
        );
        bytes memory sigs = _signFor(safe, _signers(), address(transmitter), 0, _stagedData(), Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.NoLiveRecord.selector, address(other)));
        _execWith(safe, address(transmitter), 0, _stagedData(), Enum.Operation.Call, sigs);
    }

    function test_consume_outsideExecution() public {
        vm.prank(address(transmitter));
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.NoLiveRecord.selector, address(safe)));
        guard.consume(address(safe));
    }

    function test_consume_twice() public {
        transmitter.setMode(TestTransmitter.Mode.ConsumeTwice, address(0), "");
        bytes memory sigs = _signFor(safe, _signers(), address(transmitter), 0, _stagedData(), Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.AlreadyConsumed.selector, address(safe)));
        _execWith(safe, address(transmitter), 0, _stagedData(), Enum.Operation.Call, sigs);
    }

    function test_selectorCollision_unconsumedSucceedsAndCleans() public {
        Collider collider = new Collider();
        uint256 nonce = safe.nonce();
        _run(
            _execCall(safe, _signers(), address(collider), 0, _stagedData(), Enum.Operation.Call, nonce),
            _cleared(safe, 8),
            _execCall(safe, _signers(), address(transmitter), 0, _stagedData(), Enum.Operation.Call, nonce + 1)
        );
        assertEq(collider.calls(), 1);
        assertEq(transmitter.sends(), 1);
        assertTrue(sink.consumedFirst());
    }

    function test_protectedTransmitterSkippingConsumption_isCleaned() public {
        transmitter.setMode(TestTransmitter.Mode.Skip, address(0), "");
        _run(
            _execCall(safe, _signers(), address(transmitter), 0, _stagedData(), Enum.Operation.Call, safe.nonce()),
            _cleared(safe, 8)
        );
        assertEq(transmitter.sends(), 1);
    }

    function test_delegatecallWithSendMessageSelector_stagesAndCleans() public {
        Collider collider = new Collider();
        _applyConfig(_config(address(collider), bytes4(_stagedData()), Operation.DELEGATECALL, address(allowPolicy)));
        bytes memory data = _stagedData();
        _run(
            _execCall(safe, _signers(), address(collider), 0, data, Enum.Operation.DelegateCall, safe.nonce()),
            _cleared(safe, 8)
        );
    }

    function test_sequentialSendMessages_independentRecords() public {
        bytes memory data = _stagedData();
        uint256 nonce = safe.nonce();
        _run(
            _execCall(safe, _signers(), address(transmitter), 0, data, Enum.Operation.Call, nonce),
            _execCall(safe, _signers(), address(transmitter), 0, data, Enum.Operation.Call, nonce + 1),
            _cleared(safe, 8)
        );
        assertEq(transmitter.sends(), 2);
        assertEq(
            transmitter.lastSafeTxHash(), _txHashAt(safe, address(transmitter), 0, data, Enum.Operation.Call, nonce + 1)
        );
    }

    function test_nestedSameSafe_rejectedBeforeConsumption() public {
        transmitter.setMode(TestTransmitter.Mode.CallThenConsume, address(safe), _presignedTransfer(safe.nonce() + 1));
        bytes memory sigs = _signFor(safe, _signers(), address(transmitter), 0, _stagedData(), Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.NestedExecution.selector, address(safe)));
        _execWith(safe, address(transmitter), 0, _stagedData(), Enum.Operation.Call, sigs);
    }

    function test_nestedSameSafe_rejectedAfterConsumption() public {
        transmitter.setMode(TestTransmitter.Mode.ConsumeThenCall, address(safe), _presignedTransfer(safe.nonce() + 1));
        bytes memory sigs = _signFor(safe, _signers(), address(transmitter), 0, _stagedData(), Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.NestedExecution.selector, address(safe)));
        _execWith(safe, address(transmitter), 0, _stagedData(), Enum.Operation.Call, sigs);
    }

    /// @dev Before staging, while the policy check runs, the inherited gate rejects any nested check.
    function test_nestedDuringPolicyCheck_rejected() public {
        ReenteringPolicy policy = new ReenteringPolicy();
        Safe checked = _newEoaSafe();
        SafePolicyGuard.Configuration[] memory configs = new SafePolicyGuard.Configuration[](2);
        configs[0] = _config(address(0), bytes4(0), Operation.CALL, address(policy));
        configs[1] =
            _config(address(multiSend), multiSend.multiSend.selector, Operation.DELEGATECALL, address(allowPolicy));
        _install(checked, _signers(), guard, configs, false);
        vm.deal(address(checked), 1 ether);

        uint256 nonce = checked.nonce();
        bytes32 nestedHash = _txHashAt(checked, address(0xBEEF), 1, "", Enum.Operation.Call, nonce + 1);
        policy.arm(
            address(checked), _execData(address(0xBEEF), 1, "", Enum.Operation.Call, _sign(_signers(), nestedHash))
        );
        bytes memory sigs = _signFor(checked, _signers(), address(transmitter), 0, _stagedData(), Enum.Operation.Call);
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyEngine.PolicyReverted.selector,
                address(policy),
                abi.encodeWithSelector(PolicyEngine.Reentrancy.selector)
            )
        );
        _execWith(checked, address(transmitter), 0, _stagedData(), Enum.Operation.Call, sigs);
    }

    function test_shortCalldata_rejectedBeforeStaging() public {
        bytes memory sigs = _signFor(safe, _signers(), address(transmitter), 0, hex"cdfe", Enum.Operation.Call);
        vm.expectRevert(PolicyEngine.InvalidSelector.selector);
        _execWith(safe, address(transmitter), 0, hex"cdfe", Enum.Operation.Call, sigs);
    }

    /// @dev After consumption, a module making the Safe call the transmitter again finds the record
    ///      already consumed. The Safe has no module guard here.
    function test_moduleDuringLiveRecord_cannotConsumeAgain() public {
        Module module = new Module();
        _exec(
            safe,
            _signers(),
            address(safe),
            0,
            abi.encodeCall(safe.enableModule, (address(module))),
            Enum.Operation.Call
        );
        transmitter.setMode(
            TestTransmitter.Mode.ConsumeThenCall,
            address(module),
            abi.encodeCall(Module.execStrict, (safe, address(transmitter), _stagedData(), Enum.Operation.Call))
        );
        bytes memory sigs = _signFor(safe, _signers(), address(transmitter), 0, _stagedData(), Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.AlreadyConsumed.selector, address(safe)));
        _execWith(safe, address(transmitter), 0, _stagedData(), Enum.Operation.Call, sigs);
    }

    function test_separatelySignedExecutionAfterCleanup_proceeds() public {
        uint256 nonce = safe.nonce();
        _run(
            _execCall(safe, _signers(), address(transmitter), 0, _stagedData(), Enum.Operation.Call, nonce),
            Batch.Call(address(safe), _presignedTransfer(nonce + 1), false)
        );
        assertEq(transmitter.sends(), 1);
        assertEq(address(0xBEEF).balance, 1);
    }

    function test_nestedSafeSignature_doesNotEnterChildHook() public {
        (Safe parent, Safe child) = _nestedParent();
        _install(child, _childSigners(), guard, _defaultConfig(), false);
        TestTransmitter parentTransmitter = new TestTransmitter(address(parent), sink);
        TestTransmitter childTransmitter = new TestTransmitter(address(child), sink);

        // While the child has a live record, the parent verifies a signature from the child.
        bytes memory data = _stagedData();
        bytes memory parentSigs =
            _sign(_nestedSigners(child), _txHash(parent, address(parentTransmitter), 0, data, Enum.Operation.Call));
        childTransmitter.setMode(
            TestTransmitter.Mode.ConsumeThenCall,
            address(parent),
            _execData(address(parentTransmitter), 0, data, Enum.Operation.Call, parentSigs)
        );

        assertTrue(_exec(child, _childSigners(), address(childTransmitter), 0, data, Enum.Operation.Call));
        assertEq(parentTransmitter.lastSignatures(), parentSigs);
        assertEq(childTransmitter.sends(), 1);
    }

    function test_sharedGuard_twoSafesLiveAtOnce() public {
        Safe other = _newEoaSafe();
        _install(other, _signers(), guard, _defaultConfig(), false);
        TestTransmitter otherTransmitter = new TestTransmitter(address(other), sink);
        Thief thief = new Thief();

        bytes memory data = _stagedData();
        bytes memory otherSigs =
            _sign(_signers(), _txHash(other, address(otherTransmitter), 0, data, Enum.Operation.Call));
        bytes memory nested = _execData(address(otherTransmitter), 0, data, Enum.Operation.Call, otherSigs);
        transmitter.setMode(TestTransmitter.Mode.ConsumeThenCall, address(other), nested);

        // The other Safe's transmitter first tries this Safe's record, which only this Safe's
        // transmitter may consume.
        otherTransmitter.setMode(
            TestTransmitter.Mode.CallThenConsume, address(thief), abi.encodeCall(Thief.steal, (guard, address(safe)))
        );
        bytes memory sigs = _signFor(safe, _signers(), address(transmitter), 0, data, Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.NotSignedTarget.selector, address(thief)));
        _execWith(safe, address(transmitter), 0, data, Enum.Operation.Call, sigs);

        otherTransmitter.setMode(TestTransmitter.Mode.Consume, address(0), "");
        _run(
            _execCallWith(safe, address(transmitter), 0, data, Enum.Operation.Call, sigs),
            _cleared(safe, 8),
            _cleared(other, 8)
        );
        assertEq(otherTransmitter.lastSignatures(), otherSigs);
        assertEq(transmitter.sends(), 1);
    }

    function test_failedInnerCall_revertsStagingAndConsumption() public {
        transmitter.setMode(TestTransmitter.Mode.ConsumeThenRevert, address(0), "");
        TestTransmitter second = new TestTransmitter(address(safe), sink);
        uint256 nonce = safe.nonce();
        Batch.Call memory failing =
            _execCall(safe, _signers(), address(transmitter), 0, _stagedData(), Enum.Operation.Call, nonce);
        failing.allowFailure = true;

        bytes[] memory results = _run(
            failing,
            _cleared(safe, 8),
            _execCall(safe, _signers(), address(second), 0, _stagedData(), Enum.Operation.Call, nonce)
        );
        assertEq(bytes4(results[0]), TestTransmitter.Reverted.selector);
        assertEq(second.sends(), 1);
        assertEq(safe.nonce(), nonce + 1);
    }

    function test_nonzeroSafeTxGasOrGasPrice_rejected() public {
        bytes memory data = _stagedData();
        bytes32 txHash = safe.getTransactionHash(
            address(transmitter), 0, data, Enum.Operation.Call, 1, 0, 0, address(0), payable(address(0)), safe.nonce()
        );
        bytes memory signatures = _sign(_signers(), txHash);
        vm.expectRevert(SafePolicyGuard.NonZeroSafeTxGas.selector);
        safe.execTransaction(
            address(transmitter), 0, data, Enum.Operation.Call, 1, 0, 0, address(0), payable(address(0)), signatures
        );

        txHash = safe.getTransactionHash(
            address(transmitter), 0, data, Enum.Operation.Call, 0, 0, 1, address(0), payable(address(0)), safe.nonce()
        );
        signatures = _sign(_signers(), txHash);
        vm.expectRevert(SafePolicyGuard.NonZeroGasPrice.selector);
        safe.execTransaction(
            address(transmitter), 0, data, Enum.Operation.Call, 0, 0, 1, address(0), payable(address(0)), signatures
        );
    }

    function test_sendMessageViaMultiSend_hasNoStagingPath() public {
        bytes memory data = _stagedData();
        bytes memory batchData = abi.encodePacked(uint8(0), address(transmitter), uint256(0), data.length, data);
        bytes memory call = abi.encodeCall(multiSend.multiSend, (batchData));
        bytes memory sigs = _signFor(safe, _signers(), address(multiSend), 0, call, Enum.Operation.DelegateCall);
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.NoLiveRecord.selector, address(safe)));
        _execWith(safe, address(multiSend), 0, call, Enum.Operation.DelegateCall, sigs);
    }

    function test_discovery_noGuard() public {
        Safe bare = _newEoaSafe();
        TestTransmitter bareTransmitter = new TestTransmitter(address(bare), sink);
        bytes memory sigs = _signFor(bare, _signers(), address(bareTransmitter), 0, _stagedData(), Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(GuardDiscovery.NoGuard.selector, address(bare)));
        _execWith(bare, address(bareTransmitter), 0, _stagedData(), Enum.Operation.Call, sigs);
    }

    function test_discovery_guardWithoutConsume() public {
        Safe plain = _newEoaSafe();
        SafePolicyGuard plainGuard = new SafePolicyGuard(0, 1 days);
        _install(plain, _signers(), plainGuard, _defaultConfig(), false);
        TestTransmitter plainTransmitter = new TestTransmitter(address(plain), sink);
        bytes memory sigs =
            _signFor(plain, _signers(), address(plainTransmitter), 0, _stagedData(), Enum.Operation.Call);
        // SafePolicyGuard has neither `consume` nor a fallback, so the call reverts with no data.
        vm.expectCall(address(plainGuard), abi.encodeCall(ICrossecuteGuard.consume, (address(plain))));
        vm.expectRevert(bytes(""));
        _execWith(plain, address(plainTransmitter), 0, _stagedData(), Enum.Operation.Call, sigs);
    }

    function test_discovery_ownerNotASafe() public {
        TestTransmitter eoaTransmitter = new TestTransmitter(address(this), sink);
        vm.expectRevert(abi.encodeWithSelector(GuardDiscovery.MalformedGuardSlot.selector, address(this)));
        eoaTransmitter.sendMessage("", "", new bytes[](0));
    }

    /// @dev A module swaps the guard before the transmitter discovers it. The transmitter reads the
    ///      new guard, which holds no record, and rejects.
    function test_discovery_guardChangedBeforeConsumption() public {
        CrossecuteGuardHarness replacement = new CrossecuteGuardHarness(0, 1 days);
        GuardSwapModule module = new GuardSwapModule(safe, address(replacement));
        _exec(
            safe,
            _signers(),
            address(safe),
            0,
            abi.encodeCall(safe.enableModule, (address(module))),
            Enum.Operation.Call
        );
        transmitter.setMode(
            TestTransmitter.Mode.CallThenConsume, address(module), abi.encodeCall(GuardSwapModule.swap, ())
        );
        bytes memory sigs = _signFor(safe, _signers(), address(transmitter), 0, _stagedData(), Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.NoLiveRecord.selector, address(safe)));
        _execWith(safe, address(transmitter), 0, _stagedData(), Enum.Operation.Call, sigs);
    }

    /// @dev Safe 1.5.0 sends the post-hook to the guard it read before execution, so a guard swapped
    ///      out during a `sendMessage` still clears its own record.
    function test_guardSwappedDuringSendMessage_oldGuardClears() public {
        CrossecuteGuardHarness replacement = new CrossecuteGuardHarness(0, 1 days);
        GuardSwapModule module = new GuardSwapModule(safe, address(replacement));
        _exec(
            safe,
            _signers(),
            address(safe),
            0,
            abi.encodeCall(safe.enableModule, (address(module))),
            Enum.Operation.Call
        );
        _run(
            _execCall(safe, _signers(), address(module), 0, _stagedData(), Enum.Operation.Call, safe.nonce()),
            _cleared(safe, 8)
        );
        assertEq(abi.decode(safe.getStorageAt(GuardDiscovery.GUARD_STORAGE_SLOT, 1), (address)), address(replacement));
    }

    /// @dev Only reachable through a path that lets the Safe call the guard mid-execution, here a
    ///      module on a Safe without a module guard. The sink then sees the record still live.
    function test_postHookWithOtherHash_leavesRecordLive() public {
        Module module = new Module();
        _exec(
            safe,
            _signers(),
            address(safe),
            0,
            abi.encodeCall(safe.enableModule, (address(module))),
            Enum.Operation.Call
        );
        bytes memory forged = abi.encodeCall(ISafeTransactionGuard.checkAfterExecution, (bytes32(uint256(1)), true));
        transmitter.setMode(
            TestTransmitter.Mode.ConsumeThenCall,
            address(module),
            abi.encodeCall(Module.exec, (safe, address(guard), forged, Enum.Operation.Call))
        );
        assertTrue(_exec(safe, _signers(), address(transmitter), 0, _stagedData(), Enum.Operation.Call));
        assertTrue(sink.consumedFirst());
    }

    /// @dev A Safe can call address zero, so a record's liveness must not depend on its target: the
    ///      record must block nesting and be cleared like any other.
    function test_sendMessageToAddressZero_isLiveUntilCleared() public {
        HookCaller caller = new HookCaller(guard, allowPolicy);
        caller.stageAndClear(address(0), _stagedData());
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.NestedExecution.selector, address(caller)));
        caller.stageTwice(address(0), _stagedData());
    }

    function test_directHookCaller_onlyTouchesItsOwnRecord() public {
        HookCaller caller = new HookCaller(guard, allowPolicy);
        caller.stageAndClear(address(transmitter), _stagedData());

        // During this Safe's `sendMessage`, the caller stages and clears under its own key only.
        transmitter.setMode(
            TestTransmitter.Mode.ConsumeThenCall,
            address(caller),
            abi.encodeCall(HookCaller.stageAndClear, (address(transmitter), _stagedData()))
        );
        assertTrue(_exec(safe, _signers(), address(transmitter), 0, _stagedData(), Enum.Operation.Call));
        assertTrue(sink.consumedFirst());
    }

    function _words(bytes memory signatures) internal pure returns (uint256) {
        return (signatures.length + 31) / 32;
    }

    function _presignedTransfer(uint256 nonce) internal view returns (bytes memory) {
        bytes32 txHash = _txHashAt(safe, address(0xBEEF), 1, "", Enum.Operation.Call, nonce);
        return _execData(address(0xBEEF), 1, "", Enum.Operation.Call, _sign(_signers(), txHash));
    }

    function _applyConfig(SafePolicyGuard.Configuration memory config) internal {
        Safe fresh = _newEoaSafe();
        SafePolicyGuard.Configuration[] memory base = _defaultConfig();
        SafePolicyGuard.Configuration[] memory configs = new SafePolicyGuard.Configuration[](base.length + 1);
        for (uint256 i = 0; i < base.length; ++i) {
            configs[i] = base[i];
        }
        configs[base.length] = config;
        _install(fresh, _signers(), guard, configs, false);
        safe = fresh;
        vm.deal(address(safe), 10 ether);
    }

    /// @dev Parent owned by one EOA and a 2-of-2 child Safe, threshold 2.
    function _nestedParent() internal returns (Safe parent, Safe child) {
        address[] memory childOwners = new address[](2);
        childOwners[0] = vm.addr(KEY_B);
        childOwners[1] = vm.addr(KEY_C);
        child = _newSafe(childOwners, 2);
        address[] memory parentOwners = new address[](2);
        parentOwners[0] = vm.addr(KEY_A);
        parentOwners[1] = address(child);
        parent = _newSafe(parentOwners, 2);
        _install(parent, _nestedSigners(child), guard, _defaultConfig(), false);
    }

    function _nestedSigners(Safe child) internal pure returns (Signer[] memory signers) {
        uint256[] memory childKeys = new uint256[](2);
        childKeys[0] = KEY_B;
        childKeys[1] = KEY_C;
        signers = new Signer[](2);
        signers[0] = _eoa(KEY_A);
        signers[1] = _child(child, childKeys);
    }

    function _childSigners() internal pure returns (Signer[] memory signers) {
        signers = new Signer[](2);
        signers[0] = _eoa(KEY_B);
        signers[1] = _eoa(KEY_C);
    }
}

/// @dev Calls the Safe's `setGuard` through the module path. The Safe has no module guard here.
///      Its `sendMessage` and `bootstrap` swap the guard mid-execution.
contract GuardSwapModule {
    Safe internal immutable SAFE;
    address internal immutable REPLACEMENT;

    constructor(Safe safe, address replacement) {
        SAFE = safe;
        REPLACEMENT = replacement;
    }

    function swap() public {
        require(
            SAFE.execTransactionFromModule(
                address(SAFE), 0, abi.encodeCall(SAFE.setGuard, (REPLACEMENT)), Enum.Operation.Call
            )
        );
    }

    function sendMessage(bytes calldata, bytes calldata, bytes[] calldata) external returns (bytes32) {
        swap();
        return 0;
    }

    function bootstrap(bytes calldata, bytes[] calldata) external payable {
        swap();
    }
}

/// @dev Not a Safe: configures itself on the guard and calls the owner hooks directly. It answers
///      the guard's `nonce()`.
contract HookCaller {
    CrossecuteGuardHarness internal immutable GUARD;

    constructor(CrossecuteGuardHarness guard, AllowPolicy allowPolicy) {
        GUARD = guard;
        SafePolicyGuard.Configuration[] memory configs = new SafePolicyGuard.Configuration[](1);
        configs[0] = SafePolicyGuard.Configuration(address(0), bytes4(0), Operation.CALL, address(allowPolicy), "");
        guard.configureImmediately(configs);
    }

    function stageAndClear(address to, bytes calldata data) external {
        SafeTx memory safeTx;
        (safeTx.to, safeTx.data) = (to, data);
        bytes32 txHash = SafeHashes.transactionHash(safeTx, address(this), block.chainid);
        _stage(to, data);
        require(bytes32(GUARD.recordWords(address(this), 0)[0]) == txHash);
        GUARD.checkAfterExecution(txHash, true);
        GUARD.requireCleared(address(this), 0);
    }

    function stageTwice(address to, bytes calldata data) external {
        _stage(to, data);
        _stage(to, data);
    }

    function _stage(address to, bytes calldata data) internal {
        GUARD.checkTransaction(to, 0, data, Operation.CALL, 0, 0, 0, address(0), payable(address(0)), "", address(0));
    }

    function nonce() external pure returns (uint256) {
        return 1;
    }
}

/// @dev During a check, makes the Safe being checked execute a second, separately signed transaction.
contract ReenteringPolicy is IPolicy {
    address internal safe;
    bytes internal nested;

    function arm(address safe_, bytes calldata nested_) external {
        safe = safe_;
        nested = nested_;
    }

    function checkTransaction(
        address,
        address,
        uint256,
        bytes calldata,
        Operation,
        address,
        bytes calldata,
        AccessSelector.T
    ) external returns (bytes4) {
        if (nested.length != 0) {
            (bool success, bytes memory result) = safe.call(nested);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }
        return IPolicy.checkTransaction.selector;
    }

    function configure(address, AccessSelector.T, bytes memory) external pure returns (bool) {
        return true;
    }
}
