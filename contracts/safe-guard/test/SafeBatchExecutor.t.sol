// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {SafeBatchExecutor, ISafeExec} from "../src/SafeBatchExecutor.sol";
import {GuardTestBase} from "./GuardTestBase.sol";
import {TestTransmitter} from "./TestTransmitter.sol";

contract Reverter {
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

    function setUp() public override {
        super.setUp();
        executor = new SafeBatchExecutor();
        base = new TestTransmitter(address(safe), sink);
        arbitrum = new TestTransmitter(address(safe), sink);
        vm.store(address(safe), bytes32(NONCE_SLOT), bytes32(uint256(42)));
        assertEq(safe.nonce(), 42);
    }

    function _send(TestTransmitter to, bytes memory recipient, uint256 nonce)
        internal
        view
        returns (SafeBatchExecutor.Execution memory e)
    {
        bytes memory data = abi.encodeCall(TestTransmitter.sendMessage, (recipient, hex"02", new bytes[](0)));
        e.safe = ISafeExec(address(safe));
        e.to = address(to);
        e.data = data;
        e.signatures = _sign(_signers(), _txHashAt(safe, address(to), 0, data, Enum.Operation.Call, nonce));
    }

    function _pair(SafeBatchExecutor.Execution memory a, SafeBatchExecutor.Execution memory b)
        internal
        pure
        returns (SafeBatchExecutor.Execution[] memory l)
    {
        l = new SafeBatchExecutor.Execution[](2);
        (l[0], l[1]) = (a, b);
    }

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

    function test_aRevertingSecondSendRollsBackBothSendsAndNonces() public {
        arbitrum.setMode(TestTransmitter.Mode.ConsumeThenRevert, address(0), "");
        SafeBatchExecutor.Execution[] memory batch_ = _pair(_send(base, hex"2105", 42), _send(arbitrum, hex"a4b1", 43));
        vm.expectRevert();
        executor.execute(batch_);
        assertEq(safe.nonce(), 42);
        assertEq(base.sends(), 0);
        assertEq(sink.calls(), 0);
    }

    function test_outOfOrderNoncesRevert() public {
        SafeBatchExecutor.Execution[] memory batch_ = _pair(_send(arbitrum, hex"a4b1", 43), _send(base, hex"2105", 42));
        vm.expectRevert();
        executor.execute(batch_);
        assertEq(safe.nonce(), 42);
    }

    /// @dev Safe returns `false` only for a failed inner call with nonzero `safeTxGas` or
    ///      `gasPrice`, which the guard's policy refuses, so this Safe has no guard.
    function test_aSafeReturningFalseRollsBackTheBatch() public {
        Safe plain = _newEoaSafe();
        Reverter reverter = new Reverter();
        bytes memory ok = abi.encodeWithSignature("getThreshold()");
        bytes memory bad = abi.encodeCall(Reverter.fail, ());

        SafeBatchExecutor.Execution memory first;
        first.safe = ISafeExec(address(plain));
        first.to = address(plain);
        first.data = ok;
        first.signatures = _sign(_signers(), _txHashAt(plain, address(plain), 0, ok, Enum.Operation.Call, 0));

        SafeBatchExecutor.Execution memory second;
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

        vm.expectRevert(abi.encodeWithSelector(SafeBatchExecutor.ExecutionFailed.selector, 1));
        executor.execute(_pair(first, second));
        assertEq(plain.nonce(), 0);
    }
}
