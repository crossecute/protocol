// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {SafeBatchExecutor, ISafeExec} from "../src/SafeBatchExecutor.sol";
import {GuardTestBase} from "./GuardTestBase.sol";
import {TestTransmitter} from "./TestTransmitter.sol";

contract Reverter {
    /// @notice Always revert when the Safe executes this call.
    /// @dev The batch tests need a predictable inner failure to exercise Safe's false-return
    ///      behavior.
    function fail() external pure {
        revert("no");
    }
}

/// @dev #108's atomic source batch: two separately signed sends at Safe nonces 42 and 43 in one
///      outer transaction, each staged by the real guard and consumed by its own transmitter.
contract SafeBatchExecutorTest is GuardTestBase {
    /// @dev Safe 1.5.0's `nonce` storage slot.
    uint256 constant NONCE_SLOT = 5;

    SafeBatchExecutor executor;
    TestTransmitter base;
    TestTransmitter arbitrum;

    /// @notice Deploy the batch executor and two transmitters, then set the guarded Safe nonce
    ///         to 42.
    /// @dev Consecutive signed sends can then demonstrate atomic execution and nonce rollback
    ///      with the real Safe and guard.
    function setUp() public override {
        super.setUp();
        executor = new SafeBatchExecutor();
        base = new TestTransmitter(address(safe), sink);
        arbitrum = new TestTransmitter(address(safe), sink);
        vm.store(address(safe), bytes32(NONCE_SLOT), bytes32(uint256(42)));
        assertEq(safe.nonce(), 42);
    }

    /// @notice Build and sign a transmitter send at the selected Safe nonce.
    /// @dev Each batch entry needs independent evidence so the test can detect ordering or
    ///      staged-record mixups.
    function _send(TestTransmitter to, bytes memory recipient, uint256 nonce)
        internal
        view
        returns (SafeBatchExecutor.SafeExecution memory execution)
    {
        bytes memory data = abi.encodeCall(TestTransmitter.sendMessage, (recipient, hex"02", new bytes[](0)));
        execution.safe = ISafeExec(address(safe));
        execution.to = address(to);
        execution.data = data;
        execution.signatures = _sign(_signers(), _txHashAt(safe, address(to), 0, data, Enum.Operation.Call, nonce));
    }

    /// @notice Build an execution array preserving the supplied two-transaction order.
    /// @dev Batch tests must control nonce order explicitly, including the intentionally
    ///      reversed case.
    function _pair(
        SafeBatchExecutor.SafeExecution memory firstExecution,
        SafeBatchExecutor.SafeExecution memory secondExecution
    ) internal pure returns (SafeBatchExecutor.SafeExecution[] memory executions) {
        executions = new SafeBatchExecutor.SafeExecution[](2);
        (executions[0], executions[1]) = (firstExecution, secondExecution);
    }

    /// @notice Execute two separately signed sends at nonces 42 and 43.
    /// @dev Atomic batching must advance both nonces and let each transmitter consume its own
    ///      staged record.
    function test_twoSendsAtConsecutiveNoncesRunInOneTransaction() public {
        bytes32 hash42 = _txHashAt(
            safe,
            address(base),
            0,
            abi.encodeCall(TestTransmitter.sendMessage, (hex"2105", hex"02", new bytes[](0))),
            Enum.Operation.Call,
            42
        );
        executor.execute(_pair(_send(base, hex"2105", 42), _send(arbitrum, hex"a4b1", 43)));
        assertEq(safe.nonce(), 44);
        assertEq(base.sends(), 1);
        assertEq(arbitrum.sends(), 1);
        assertEq(base.lastSafeTxHash(), hash42, "each send consumed its own record");
        assertTrue(arbitrum.lastSafeTxHash() != hash42);
    }

    /// @notice Make the second transmitter revert after the first send has run.
    /// @dev The executor must undo earlier effects and both Safe nonce advances instead of
    ///      leaving a partial batch.
    function test_aRevertingSecondSendRollsBackBothSendsAndNonces() public {
        arbitrum.setMode(TestTransmitter.Mode.ConsumeThenRevert, address(0), "");
        SafeBatchExecutor.SafeExecution[] memory executions =
            _pair(_send(base, hex"2105", 42), _send(arbitrum, hex"a4b1", 43));
        vm.expectRevert();
        executor.execute(executions);
        assertEq(safe.nonce(), 42);
        assertEq(base.sends(), 0);
        assertEq(sink.calls(), 0);
    }

    /// @notice Submit the two signed Safe transactions in reverse nonce order.
    /// @dev The executor must preserve Safe's nonce rules rather than treating signatures as
    ///      freely reorderable calls.
    function test_outOfOrderNoncesRevert() public {
        SafeBatchExecutor.SafeExecution[] memory executions =
            _pair(_send(arbitrum, hex"a4b1", 43), _send(base, hex"2105", 42));
        vm.expectRevert();
        executor.execute(executions);
        assertEq(safe.nonce(), 42);
    }

    /// @notice Run a successful call followed by a Safe inner call that returns `false`.
    /// @dev False must trigger the same complete batch rollback as a revert. This fixture uses
    ///      an unguarded Safe because the guard refuses the nonzero gas settings needed for
    ///      that return path.
    function test_aSafeReturningFalseRollsBackTheBatch() public {
        Safe plain = _newEoaSafe();
        Reverter reverter = new Reverter();
        bytes memory ok = abi.encodeWithSignature("getThreshold()");
        bytes memory bad = abi.encodeCall(Reverter.fail, ());

        SafeBatchExecutor.SafeExecution memory first;
        first.safe = ISafeExec(address(plain));
        first.to = address(plain);
        first.data = ok;
        first.signatures = _sign(_signers(), _txHashAt(plain, address(plain), 0, ok, Enum.Operation.Call, 0));

        SafeBatchExecutor.SafeExecution memory second;
        second.safe = ISafeExec(address(plain));
        second.to = address(reverter);
        second.data = bad;
        second.safeTxGas = 50_000;
        second.signatures = _sign(
            _signers(),
            plain.getTransactionHash(
                address(reverter), 0, bad, Enum.Operation.Call, 50_000, 0, 0, address(0), payable(address(0)), 1
            )
        );

        vm.expectRevert(abi.encodeWithSelector(SafeBatchExecutor.SafeExecutionFailed.selector, 1));
        executor.execute(_pair(first, second));
        assertEq(plain.nonce(), 0);
    }
}
