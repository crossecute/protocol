// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ITransactionGuard} from "safe-interface/base/GuardManager.sol";
import {IERC165} from "safe-interface/interfaces/IERC165.sol";
import {Enum} from "safe-interface/libraries/Enum.sol";
import {Enum as FixtureEnum} from "safe-fixture/common/Enum.sol";
import {Guard} from "safe-fixture/base/GuardManager.sol";
import {SafeGuardFixture} from "./SafeGuardFixture.sol";
import {TransactionGuardHarness} from "./TransactionGuardHarness.sol";

contract HookTarget {
    bytes32 public recorded;

    function record(bytes32 value) external payable {
        recorded = value;
    }

    function fail() external pure {
        revert("inner failure");
    }

    function echo(bytes32 value) external pure returns (bytes32) {
        return value;
    }
}

contract TransactionGuardTest is SafeGuardFixture {
    function testInterfaceSupport() public view {
        assertTrue(guard.supportsInterface(type(ITransactionGuard).interfaceId));
        assertTrue(guard.supportsInterface(type(IERC165).interfaceId));
        assertFalse(guard.supportsInterface(0xffffffff));
        assertFalse(guard.supportsInterface(bytes4(0)));
        assertEq(type(ITransactionGuard).interfaceId, bytes4(0xe6d7a83a));
        assertEq(Guard.checkTransaction.selector, ITransactionGuard.checkTransaction.selector);
        assertEq(Guard.checkAfterExecution.selector, ITransactionGuard.checkAfterExecution.selector);
    }

    function testSignedInstallationUsesRealSafe130() public view {
        assertEq(safe.VERSION(), "1.3.0");
        assertEq(_installedGuard(), address(guard));
        assertEq(safe.nonce(), 1);
        assertEq(guard.preCalls(), 0);
        assertEq(guard.postCalls(), 0);
    }

    function testSignedCallPreservesHookArgumentsAndDigest() public {
        HookTarget target = new HookTarget();
        SafeTransaction memory txn = _transaction(address(target), abi.encodeCall(target.record, (bytes32("payload"))));
        txn.value = 0.1 ether;
        txn.baseGas = 123;
        txn.gasToken = address(0xbeef);
        txn.refundReceiver = payable(address(0xcafe));
        bytes memory signatures = _sign(txn);
        bytes32 digest = _digest(txn);

        assertTrue(_execute(txn, signatures));

        assertEq(target.recorded(), bytes32("payload"));
        assertEq(address(target).balance, txn.value);
        assertEq(guard.preCalls(), 1);
        assertEq(guard.postCalls(), 1);
        assertEq(guard.signedNonce(), txn.nonce);
        assertEq(guard.preDigest(), digest);
        assertEq(guard.postDigest(), digest);
        assertEq(guard.signatures(), signatures);
        assertEq(guard.executor(), address(this));
        assertTrue(guard.success());
    }

    function testReturnedFailureStillCallsPostHook() public {
        HookTarget target = new HookTarget();
        SafeTransaction memory txn = _transaction(address(target), abi.encodeCall(target.fail, ()));
        txn.safeTxGas = 100_000;
        assertFalse(_execute(txn, _sign(txn)));
        assertEq(guard.preCalls(), 1);
        assertEq(guard.postCalls(), 1);
        assertEq(guard.preDigest(), _digest(txn));
        assertEq(guard.postDigest(), _digest(txn));
        assertFalse(guard.success());
    }

    function testDelegateCallOperationEncoding() public {
        HookTarget target = new HookTarget();
        SafeTransaction memory txn = _transaction(address(target), abi.encodeCall(target.echo, (bytes32("delegate"))));
        txn.operation = FixtureEnum.Operation.DelegateCall;
        assertTrue(_execute(txn, _sign(txn)));
        assertEq(guard.preDigest(), _digest(txn));
        assertEq(guard.postDigest(), _digest(txn));
        assertTrue(guard.success());
    }

    function testWholeSafeRevertRollsBackHooks() public {
        HookTarget target = new HookTarget();
        SafeTransaction memory txn = _transaction(address(target), abi.encodeCall(target.fail, ()));
        bytes memory signatures = _sign(txn);
        vm.expectRevert(bytes("GS013"));
        _execute(txn, signatures);
        assertEq(guard.preCalls(), 0);
        assertEq(guard.postCalls(), 0);
        assertEq(safe.nonce(), txn.nonce);
    }

    function testReplacementPostsToOriginalGuard() public {
        TransactionGuardHarness replacement = new TransactionGuardHarness(address(safe));
        _setGuard(address(replacement));
        assertEq(_installedGuard(), address(replacement));
        assertEq(guard.preCalls(), 1);
        assertEq(guard.postCalls(), 1);
        assertEq(replacement.preCalls(), 0);
        assertEq(replacement.postCalls(), 0);

        HookTarget target = new HookTarget();
        SafeTransaction memory txn = _transaction(address(target), abi.encodeCall(target.record, (bytes32("next"))));
        assertTrue(_execute(txn, _sign(txn)));
        assertEq(replacement.preCalls(), 1);
        assertEq(replacement.postCalls(), 1);
    }

    function testRemovalPostsToOriginalGuard() public {
        _setGuard(address(0));
        assertEq(_installedGuard(), address(0));
        assertEq(guard.preCalls(), 1);
        assertEq(guard.postCalls(), 1);
    }

    function testRejectsDirectHookCalls() public {
        vm.expectRevert(TransactionGuardHarness.UnauthorizedSafe.selector);
        guard.checkTransaction(
            address(0), 0, "", Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), "", address(this)
        );
        vm.expectRevert(TransactionGuardHarness.UnauthorizedSafe.selector);
        guard.checkAfterExecution(bytes32(0), true);
    }
}
