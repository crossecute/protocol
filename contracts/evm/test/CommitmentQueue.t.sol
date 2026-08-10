// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Executor} from "src/messaging/Executor.sol";
import {Call} from "src/messaging/Call.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {Executor} from "src/messaging/Executor.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";

/// @dev Records the order calls actually landed in, so ordering assertions are about
///      execution rather than about bookkeeping.
contract Ledger {
    uint256[] public seen;

    function note(uint256 x) external {
        seen.push(x);
    }

    function count() external view returns (uint256) {
        return seen.length;
    }

    /// @dev A target that always fails, to build an approval that can never be discharged.
    function boom() external pure {
        revert("boom");
    }
}

contract QueueReceiver is ReceiverBase {
    function isAllowed(address, bytes4) public pure override returns (bool) {
        return true;
    }
}

/// @notice The approval queue: ordered execution, cancellation, and the relationship
///         between the two.
contract CommitmentQueueTest is Test {
    QueueReceiver r;
    Ledger ledger;

    address constant TRANSMITTER = address(0x7A11);

    function setUp() public {
        ledger = new Ledger();
        r = new QueueReceiver();
        r.initialize(TRANSMITTER, new Call[](0));
        // The transmitter is the only party that may queue or withdraw an approval. The
        // test contract created this receiver and has no authority over it afterwards,
        // which is the property being relied on rather than worked around.
        vm.startPrank(TRANSMITTER);
    }

    /* ================================== ordering ================================ */

    function test_anEmptyReceiverHasNothingPending() public view {
        assertEq(r.pendingCount(), 0);
        assertEq(r.commitment(), bytes32(0));
        assertEq(r.queueLength(), 0);
        assertEq(r.head(), 0);
    }

    function test_commitReturnsAStableIndex() public {
        assertEq(r.commit(_hash(1)), 0);
        assertEq(r.commit(_hash(2)), 1);
        assertEq(r.commit(_hash(3)), 2);
        assertEq(r.queueLength(), 3);
        assertEq(r.pendingCount(), 3);
    }

    /// @dev THE RULE: `finalize` takes the oldest outstanding approval and nothing else.
    ///      A relayer holding two valid payloads cannot choose which lands first.
    function test_finalizeTakesTheHeadAndOnlyTheHead() public {
        r.commit(_hash(1));
        r.commit(_hash(2));

        vm.expectRevert(ReceiverBase.CommitmentMismatch.selector);
        r.finalize(_calls(2));

        r.finalize(_calls(1));
        r.finalize(_calls(2));

        assertEq(ledger.seen(0), 1);
        assertEq(ledger.seen(1), 2);
    }

    function test_finalizeOnAnEmptyQueueReverts() public {
        vm.expectRevert(ReceiverBase.NothingCommitted.selector);
        r.finalize(_calls(1));
    }

    /// @dev Two identical payloads are two separate approvals, and each needs its own
    ///      finalize. A single slot could not express this at all.
    function test_identicalPayloadsAreSeparateApprovals() public {
        r.commit(_hash(7));
        r.commit(_hash(7));

        r.finalize(_calls(7));
        assertEq(r.pendingCount(), 1, "the second approval survives the first");
        r.finalize(_calls(7));
        assertEq(r.pendingCount(), 0);
        assertEq(ledger.count(), 2, "it ran twice, because it was approved twice");
    }

    /// @dev A consumed entry keeps its value and is passed by the head pointer; a
    ///      cancelled one is zeroed. That is what keeps the two distinguishable after the
    ///      fact rather than collapsing into one state.
    function test_aConsumedEntryIsDistinguishableFromACancelledOne() public {
        r.commit(_hash(1));
        r.commit(_hash(2));
        r.cancel(1, _hash(2));
        r.finalize(_calls(1));

        assertEq(r.commitmentAt(0), _hash(1), "executed: value kept, below head");
        assertEq(r.head(), 1);
        assertEq(r.commitmentAt(1), bytes32(0), "cancelled: zeroed");
    }

    /* ================================ batch finalize ============================ */

    function test_batchFinalizeRunsTheQueueInOrder() public {
        r.commit(_hash(1));
        r.commit(_hash(2));
        r.commit(_hash(3));

        Call[][] memory batches = new Call[][](3);
        batches[0] = _calls(1);
        batches[1] = _calls(2);
        batches[2] = _calls(3);
        r.finalize(batches);

        assertEq(r.pendingCount(), 0);
        assertEq(ledger.seen(0), 1);
        assertEq(ledger.seen(1), 2);
        assertEq(ledger.seen(2), 3);
    }

    /// @dev It is the same FIFO rule applied repeatedly, not a way to pick entries out of
    ///      order.
    function test_batchFinalizeCannotReorderTheQueue() public {
        r.commit(_hash(1));
        r.commit(_hash(2));

        Call[][] memory batches = new Call[][](2);
        batches[0] = _calls(2);
        batches[1] = _calls(1);

        vm.expectRevert(ReceiverBase.CommitmentMismatch.selector);
        r.finalize(batches);
    }

    /// @dev ALL OR NOTHING. A prefix would discharge approvals whose payloads never
    ///      completed and leave the head advanced past them unrepeatably.
    function test_aFailureLateInABatchRevertsTheWholeBatch() public {
        r.commit(_hash(1));
        r.commit(_failingHash());

        Call[][] memory batches = new Call[][](2);
        batches[0] = _calls(1);
        batches[1] = _failingCalls();

        vm.expectRevert();
        r.finalize(batches);

        assertEq(r.pendingCount(), 2, "the queue did not move");
        assertEq(ledger.count(), 0, "and the first payload did not stick");
    }

    function test_anEmptyBatchIsRefused() public {
        vm.expectRevert(ReceiverBase.EmptyBatch.selector);
        r.finalize(new Call[][](0));
    }

    /* ================================ cancellation ============================== */

    function test_cancelRemovesAnApprovalFromTheQueue() public {
        r.commit(_hash(1));
        r.commit(_hash(2));

        r.cancel(0, _hash(1));

        assertEq(r.pendingCount(), 1);
        assertEq(r.commitment(), _hash(2), "the survivor moved to the head");

        vm.expectRevert(ReceiverBase.CommitmentMismatch.selector);
        r.finalize(_calls(1));

        r.finalize(_calls(2));
        assertEq(ledger.seen(0), 2);
    }

    /// @dev THE WHOLE REASON CANCEL EXISTS. Ordered execution means a payload that can
    ///      never succeed stalls everything behind it, until it is withdrawn.
    function test_cancelUnblocksAQueueStuckOnAFailingPayload() public {
        r.commit(_failingHash());
        r.commit(_hash(2));

        // Head-of-line blocking, demonstrated rather than asserted in a comment.
        vm.expectRevert();
        r.finalize(_failingCalls());
        vm.expectRevert(ReceiverBase.CommitmentMismatch.selector);
        r.finalize(_calls(2));

        r.cancel(0, _failingHash());

        r.finalize(_calls(2));
        assertEq(ledger.seen(0), 2, "the queue moves again");
    }

    function test_cancelSkipsARunOfCancelledEntries() public {
        r.commit(_hash(1));
        r.commit(_hash(2));
        r.commit(_hash(3));
        r.cancel(0, _hash(1));
        r.cancel(1, _hash(2));

        assertEq(r.commitment(), _hash(3));
        assertEq(r.nextIndex(), 2);
        r.finalize(_calls(3));
        assertEq(r.pendingCount(), 0);
    }

    function test_cancellingEverythingLeavesNothingToFinalize() public {
        r.commit(_hash(1));
        r.cancel(0, _hash(1));

        assertEq(r.pendingCount(), 0);
        assertEq(r.commitment(), bytes32(0));
        vm.expectRevert(ReceiverBase.NothingCommitted.selector);
        r.finalize(_calls(1));
    }

    function test_cancelTwiceIsRefused() public {
        r.commit(_hash(1));
        r.cancel(0, _hash(1));

        vm.expectRevert(abi.encodeWithSelector(ReceiverBase.AlreadyCancelled.selector, 0));
        r.cancel(0, _hash(1));
    }

    /// @dev Refused rather than treated as a no-op: reporting success would suggest a
    ///      payload had been stopped when it has already run.
    function test_anExecutedApprovalCannotBeCancelled() public {
        r.commit(_hash(1));
        r.finalize(_calls(1));

        vm.expectRevert(abi.encodeWithSelector(ReceiverBase.AlreadyConsumed.selector, 0));
        r.cancel(0, _hash(1));
    }

    /// @dev THE OFF-BY-ONE THAT WOULD OTHERWISE BE SILENT. Cancelling the wrong slot
    ///      succeeds and simply loses a payload nobody chose to drop; the first sign is a
    ///      `finalize` that stops matching. Naming the approval as well as the slot
    ///      turns that into a revert.
    function test_cancelRefusesAStaleIndex() public {
        r.commit(_hash(1));
        r.commit(_hash(2));

        vm.expectRevert(
            abi.encodeWithSelector(
                ReceiverBase.CancelMismatch.selector, uint256(1), _hash(2), _hash(1)
            )
        );
        r.cancel(1, _hash(1));

        assertEq(r.pendingCount(), 2, "nothing was withdrawn");
    }

    function test_cancelRejectsAnIndexPastTheQueue() public {
        r.commit(_hash(1));

        vm.expectRevert(abi.encodeWithSelector(ReceiverBase.IndexOutOfRange.selector, 5));
        r.cancel(5, _hash(1));
    }

    /// @dev GATED EXACTLY LIKE `commit`. Leaving it open would hand any caller a way to
    ///      strip approvals, which is the one direction that would be an escalation.
    function test_cancelIsGatedOnTheSameBarAsCommit() public {
        r.commit(_hash(1));

        // Step out of the standing transmitter prank to speak as somebody else.
        vm.stopPrank();
        vm.prank(address(0xBAD));
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        r.cancel(0, _hash(1));

        // The source transmitter queued it, so the source transmitter may withdraw it.
        vm.startPrank(TRANSMITTER);
        r.cancel(0, _hash(1));
        assertEq(r.pendingCount(), 0);
    }

    /* ============================ reentrancy on the head ======================== */

    /// @dev TWO DEFENCES, AND THE OUTER ONE FIRES FIRST. `finalize` is `nonReentrant`, so
    ///      a payload that re-enters is stopped before it can reach the queue at all.
    ///      Underneath that, the head still advances BEFORE `_execute`, so even without
    ///      the guard a re-entrant call would find its own approval already spent. This
    ///      asserts the guard; `test_theHeadIsSpentBeforeExecution` asserts the other.
    function test_reentrantFinalizeIsRefused() public {
        Reenterer bad = new Reenterer();
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(bad),
            value: 0,
            data: abi.encodeCall(Reenterer.attack, ())
        });

        bytes32 h = Commitment.hashCalls(ChainKey.local(), calls);
        r.commit(h);
        bad.arm(r, calls);

        // The inner revert is the proof: the re-entrant `finalize` found NOTHING pending,
        // because the head had already moved past this approval before the call ran. Had
        // it advanced afterwards, the re-entrant call would have matched and executed the
        // payload a second time against one approval.
        vm.expectRevert(
            abi.encodeWithSelector(
                Executor.CallFailed.selector,
                uint256(0),
                abi.encodeWithSelector(
                    ReentrancyGuard.ReentrancyGuardReentrantCall.selector
                )
            )
        );
        r.finalize(calls);
    }

    /* ================================== helpers ================================= */

    function _hash(uint256 x) internal view returns (bytes32) {
        return Commitment.hashCalls(ChainKey.local(), _calls(x));
    }

    function _calls(uint256 x) internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: address(ledger),
            value: 0,
            data: abi.encodeCall(Ledger.note, (x))
        });
    }

    function _failingHash() internal view returns (bytes32) {
        return Commitment.hashCalls(ChainKey.local(), _failingCalls());
    }

    function _failingCalls() internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] =
            Call({target: address(ledger), value: 0, data: abi.encodeCall(Ledger.boom, ())});
    }
}

/// @dev Reads the receiver's pending count from inside the payload it is executing.
contract Peeker {
    uint256 public pendingDuring = type(uint256).max;

    function look(address receiver) external {
        pendingDuring = QueueReceiver(payable(receiver)).pendingCount();
    }
}

/// @dev Re-enters `finalize` with the same array while the first is still executing.
contract Reenterer {
    QueueReceiver private _r;
    Call[] private _calls;

    function arm(QueueReceiver r_, Call[] memory calls) external {
        _r = r_;
        delete _calls;
        for (uint256 i; i < calls.length; ++i) {
            _calls.push(calls[i]);
        }
    }

    function attack() external {
        _r.finalize(_calls);
    }
}
