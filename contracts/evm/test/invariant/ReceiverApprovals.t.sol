// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Call} from "src/messaging/Call.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {AnyGatewayReceiver} from "test/Harness.sol";
import {deployConduit} from "test/DeployCrossProxy.sol";

contract ApprovalReceiver is AnyGatewayReceiver {}

/// @dev What a payload does when it runs, counted per payload.
contract Target {
    mapping(uint256 payload => uint256) public runs;

    error Refused();

    function run(uint256 payload) external {
        ++runs[payload];
    }

    function refuse() external pure {
        revert Refused();
    }

    /// @dev Re-enters the receiver that called it, which `nonReentrant` refuses.
    function reenter(Call[] calldata calls) external {
        ReceiverBase(payable(msg.sender)).finalize(calls);
    }
}

/// @notice The source transmitter, and the only actor: commits, cancels, and finalizes against a
///         small pool of payloads so that approvals pile up on one hash, and tracks what each
///         call must have done.
/// @dev Expectations are written before the call they describe: an unexpected revert undoes
///      them with the call, and `fail-on-revert` reports it.
contract ApprovalHandler is Test {
    uint256 constant POOL = 4;
    bytes32 constant ELSEWHERE = keccak256("another chain");

    ReceiverBase public receiver;
    Target public target;

    /// Payloads 0..POOL-1 run; POOL refuses; POOL+1 re-enters.
    Call[][] internal _payloads;
    mapping(bytes32 => uint256) public expected;
    mapping(uint256 => uint256) public expectedRuns;
    bytes32[] public hashes;

    constructor(Target target_) {
        target = target_;
        for (uint256 i; i < POOL; ++i) {
            Call[] storage p = _payloads.push();
            for (uint256 j; j <= i % 2; ++j) {
                p.push(Call(address(target_), 0, abi.encodeCall(Target.run, (i))));
            }
        }
        _payloads.push().push(Call(address(target_), 0, abi.encodeCall(Target.refuse, ())));
        Call[] memory inner = new Call[](1);
        inner[0] = Call(address(target_), 0, abi.encodeCall(Target.run, (0)));
        _payloads.push().push(Call(address(target_), 0, abi.encodeCall(Target.reenter, (inner))));

        for (uint256 i; i < _payloads.length; ++i) {
            hashes.push(Commitment.hashCalls(_payloads[i]));
            hashes.push(Commitment.hashCalls(ELSEWHERE, _payloads[i]));
        }
    }

    function setReceiver(ReceiverBase r) external {
        receiver = r;
    }

    function hashCount() external view returns (uint256) {
        return hashes.length;
    }

    function commit(uint256 seed, bool elsewhere) external {
        uint256 i = seed % _payloads.length;
        bytes32 h = elsewhere ? Commitment.hashCalls(ELSEWHERE, _payloads[i]) : Commitment.hashCalls(_payloads[i]);
        assertEq(receiver.commit(h), ++expected[h], "commit returns the new count");
    }

    function cancel(uint256 seed) external {
        bytes32 h = hashes[seed % hashes.length];
        if (expected[h] == 0) {
            vm.expectRevert(abi.encodeWithSelector(ReceiverBase.NotCommitted.selector, h));
            receiver.cancel(h);
            return;
        }
        expected[h] = 0;
        receiver.cancel(h);
    }

    /// @dev Finalizing is permissionless, so the caller is anyone.
    function finalize(uint256 seed, address caller) external {
        uint256 i = seed % _payloads.length;
        bytes32 h = Commitment.hashCalls(_payloads[i]);
        vm.prank(caller);
        if (expected[h] == 0) {
            vm.expectRevert(ReceiverBase.CommitmentMismatch.selector);
            receiver.finalize(_payloads[i]);
        } else if (i >= POOL) {
            // A payload that reverts takes its approval back with it, so a retry starts clean.
            vm.expectRevert();
            receiver.finalize(_payloads[i]);
        } else {
            --expected[h];
            expectedRuns[i] += _payloads[i].length;
            receiver.finalize(_payloads[i]);
        }
    }

    /// @dev All or nothing: the batch commits only if every member is approved and runs.
    function finalizeBatch(uint256 a, uint256 b) external {
        uint256 i = a % _payloads.length;
        uint256 j = b % _payloads.length;
        bytes32 hi = Commitment.hashCalls(_payloads[i]);
        bytes32 hj = Commitment.hashCalls(_payloads[j]);
        Call[][] memory batch = new Call[][](2);
        batch[0] = _payloads[i];
        batch[1] = _payloads[j];

        uint256 needed = hi == hj ? 2 : 1;
        bool ok = i < POOL && j < POOL && expected[hi] >= needed && expected[hj] >= 1;
        if (!ok) {
            vm.expectRevert();
            receiver.finalize(batch);
            return;
        }
        --expected[hi];
        --expected[hj];
        expectedRuns[i] += _payloads[i].length;
        expectedRuns[j] += _payloads[j].length;
        receiver.finalize(batch);
    }
}

/// @notice `message-flow.md`'s approval invariants, under any sequence of commits, cancels, and
///         finalizes: approvals are a map of hash to outstanding count, a commitment for another
///         chain never finalizes here, and a payload that fails leaves its approval in place.
contract ReceiverApprovalsInvariantTest is Test {
    ApprovalHandler handler;
    ReceiverBase receiver;
    Target target;

    function setUp() public {
        target = new Target();
        handler = new ApprovalHandler(target);
        receiver = ReceiverBase(
            payable(deployConduit(
                    address(new ApprovalReceiver()),
                    abi.encodeCall(ReceiverBase.initialize, (address(handler), ChainKey.local(), new Call[](0)))
                ))
        );
        handler.setReceiver(receiver);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ApprovalHandler.commit.selector;
        selectors[1] = ApprovalHandler.cancel.selector;
        selectors[2] = ApprovalHandler.finalize.selector;
        selectors[3] = ApprovalHandler.finalizeBatch.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 100
    function invariant_outstandingIsCommitsLessFinalizes() public view {
        uint256 held;
        for (uint256 i; i < handler.hashCount(); ++i) {
            bytes32 h = handler.hashes(i);
            uint256 want = handler.expected(h);
            assertEq(receiver.outstanding(h), want, "outstanding");
            assertEq(receiver.isCommitted(h), want != 0, "isCommitted");
            if (want != 0) ++held;
        }
        assertEq(receiver.pendingCount(), held, "pendingCount");
        assertEq(receiver.commitments().length, held, "commitments");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 100
    function invariant_eachFinalizeRanItsCallsOnce() public view {
        for (uint256 i; i < 4; ++i) {
            assertEq(target.runs(i), handler.expectedRuns(i), "runs");
        }
    }
}
