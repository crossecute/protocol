// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Executor} from "src/messaging/Executor.sol";
import {Call} from "src/messaging/Call.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {InboundBase} from "src/messaging/inbound/InboundBase.sol";
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
    /// @dev A HARNESS TRUSTS ANY GATEWAY, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }

    function isAllowed(address, bytes4) public pure override returns (bool) {
        return true;
    }
}

/// @notice The approval map: unordered discharge, duplicate approvals, and cancellation.
///
/// @dev THE PROPERTY THAT REPLACED FIFO. An array names its own approval by hashing to it,
///      so nothing executes by position and nothing can block: a payload nobody relays sits
///      outstanding while every other approval discharges around it. What is given up is
///      ordering, which the payloads themselves now have to express.
contract CommitmentQueueTest is Test {
    QueueReceiver r;
    Ledger ledger;

    address constant TRANSMITTER = address(0x7A11);

    function setUp() public {
        ledger = new Ledger();
        r = new QueueReceiver();
        r.initialize(TRANSMITTER, new Call[](0));
        // The transmitter is the only party that may approve or withdraw. The test contract
        // created this receiver and has no authority over it afterwards, which is the
        // property being relied on rather than worked around.
        vm.startPrank(TRANSMITTER);
    }

    /* ================================= approving ================================ */

    function test_anEmptyReceiverHasNothingOutstanding() public view {
        assertEq(r.pendingCount(), 0);
        assertEq(r.commitments().length, 0);
        assertFalse(r.isCommitted(_hash(1)));
        assertEq(r.outstanding(_hash(1)), 0);
    }

    function test_commitReturnsTheOutstandingCount() public {
        assertEq(r.commit(_hash(1)), 1);
        assertEq(r.commit(_hash(2)), 1);
        assertEq(r.pendingCount(), 2, "two distinct approvals");
    }

    function test_aZeroCommitmentIsRefused() public {
        vm.expectRevert(InboundBase.ZeroCommitment.selector);
        r.commit(bytes32(0));
    }

    /* ================================ unordered ================================= */

    /// @dev THE RULE: `finalize` discharges the approval its array matches, whichever that
    ///      is. Approving 1 then 2 and finalizing 2 first is not a reordering to be
    ///      prevented; it is the point.
    function test_finalizeTakesWhicheverArrayItIsHanded() public {
        r.commit(_hash(1));
        r.commit(_hash(2));

        r.finalize(_calls(2));
        assertEq(ledger.seen(0), 2, "the second approval ran first");
        assertEq(r.pendingCount(), 1);
        assertTrue(r.isCommitted(_hash(1)), "and the first is untouched");

        r.finalize(_calls(1));
        assertEq(r.pendingCount(), 0);
    }

    /// @dev THE WHOLE REASON THE QUEUE WENT. Under FIFO a payload that can never succeed
    ///      stalled everything approved after it until it was cancelled. Here it stalls
    ///      nothing: it simply stays outstanding.
    function test_anUndischargeablePayloadBlocksNothing() public {
        r.commit(_failingHash());
        r.commit(_hash(1));

        r.finalize(_calls(1));
        assertEq(ledger.seen(0), 1, "the good payload ran with the bad one still pending");
        assertTrue(r.isCommitted(_failingHash()), "which is still there to cancel or retry");
    }

    function test_anUnapprovedArrayIsRefused() public {
        vm.expectRevert(InboundBase.CommitmentMismatch.selector);
        r.finalize(_calls(1));

        r.commit(_hash(1));
        vm.expectRevert(InboundBase.CommitmentMismatch.selector);
        r.finalize(_calls(2));
    }

    /// @dev Two identical payloads are two separate approvals: a set would have collapsed
    ///      them, so approving the same transfer twice would have bought one.
    function test_identicalPayloadsAreSeparateApprovals() public {
        r.commit(_hash(1));
        assertEq(r.commit(_hash(1)), 2, "counted, not deduplicated");
        assertEq(r.pendingCount(), 1, "one distinct hash");

        r.finalize(_calls(1));
        assertEq(r.outstanding(_hash(1)), 1, "one copy left");
        r.finalize(_calls(1));

        assertEq(ledger.count(), 2, "it ran twice, once per approval");
        assertFalse(r.isCommitted(_hash(1)), "and the entry left the map at zero");
    }

    /* ================================== batches ================================= */

    function test_batchFinalizeDischargesEachArray() public {
        r.commit(_hash(1));
        r.commit(_hash(2));
        r.commit(_hash(3));

        Call[][] memory batches = new Call[][](3);
        batches[0] = _calls(3);
        batches[1] = _calls(1);
        batches[2] = _calls(2);
        r.finalize(batches);

        assertEq(ledger.seen(0), 3, "in the order given, which is the caller's to choose");
        assertEq(ledger.seen(1), 1);
        assertEq(ledger.seen(2), 2);
        assertEq(r.pendingCount(), 0);
    }

    /// @dev ALL OR NOTHING. Each entry is decremented before its payload runs, so a prefix
    ///      standing would discharge approvals whose payloads never completed.
    function test_aFailureLateInABatchRevertsTheWholeBatch() public {
        r.commit(_hash(1));
        r.commit(_failingHash());

        Call[][] memory batches = new Call[][](2);
        batches[0] = _calls(1);
        batches[1] = _failingCalls();

        vm.expectRevert();
        r.finalize(batches);

        assertEq(ledger.count(), 0, "nothing ran");
        assertEq(r.pendingCount(), 2, "and nothing was spent");
    }

    function test_anEmptyBatchIsRefused() public {
        vm.expectRevert(InboundBase.EmptyBatch.selector);
        r.finalize(new Call[][](0));
    }

    /* ================================ cancelling ================================ */

    function test_cancelRemovesAnApproval() public {
        r.commit(_hash(1));
        r.cancel(_hash(1));

        assertFalse(r.isCommitted(_hash(1)));
        vm.expectRevert(InboundBase.CommitmentMismatch.selector);
        r.finalize(_calls(1));
    }

    /// @dev IT ZEROES THE ENTRY, NOT ONE COPY. A payload that turns out to be wrong is
    ///      wrong in every copy; re-approving is one `commit` away if only some were meant
    ///      to go.
    function test_cancelDropsEveryCopyOfAnApproval() public {
        r.commit(_hash(1));
        r.commit(_hash(1));
        r.commit(_hash(1));

        r.cancel(_hash(1));
        assertEq(r.outstanding(_hash(1)), 0);
    }

    /// @dev Refused rather than treated as a no-op: reporting success would suggest a
    ///      payload had been stopped when it may already have run.
    function test_cancellingWhatIsNotThereIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(InboundBase.NotCommitted.selector, _hash(1))
        );
        r.cancel(_hash(1));

        r.commit(_hash(1));
        r.finalize(_calls(1));
        vm.expectRevert(
            abi.encodeWithSelector(InboundBase.NotCommitted.selector, _hash(1))
        );
        r.cancel(_hash(1));
    }

    /// @dev GATED EXACTLY LIKE `commit`. Leaving it open would hand any caller a way to
    ///      strip approvals.
    function test_cancelIsGatedOnTheSameBarAsCommit() public {
        r.commit(_hash(1));
        vm.stopPrank();

        vm.prank(address(0xBAD));
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        r.cancel(_hash(1));

        assertTrue(r.isCommitted(_hash(1)));
    }

    /* ============================ reentrancy on an approval ===================== */

    /// @dev TWO DEFENCES, AND THE OUTER ONE FIRES FIRST. `finalize` is `nonReentrant`, so a
    ///      payload that re-enters is stopped before it can reach the map at all.
    ///      Underneath that, the count is decremented BEFORE `_execute`, so even without the
    ///      guard a re-entrant call would find that copy of the approval already spent.
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
