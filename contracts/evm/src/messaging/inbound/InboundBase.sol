// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Call} from "src/messaging/Call.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Executor} from "src/messaging/Executor.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Roles} from "src/messaging/Roles.sol";
import {IERC7786Recipient} from "src/messaging/IErc7786.sol";

/// @notice Two-step execution: approve a hash now, supply the matching array later.
///
/// @dev `commit` is gated and `finalize` is not, and that is the whole point: the approval
///      lives in the hash, so the only array that does anything is one already approved and
///      whoever relays it is irrelevant.
interface ICommitFinalize {
    function commit(bytes32 commitment) external returns (uint256 approvals);
    function finalize(Call[] calldata calls) external;
    function finalize(Call[][] calldata batches) external;
}

/// @notice Withdrawing an approval.
/// @dev THE SIGNATURE IS SHARED AND THE GATE IS NOT. An account answers to its transmitter;
///      a transceiver answers only to a payload it is already executing, which means one that
///      arrived from its authenticated counterpart. Neither is reachable by an arbitrary
///      caller, which is the property that matters on a contract every owner's bootstrap goes
///      through.
interface ICancel {
    function cancel(bytes32 commitment) external;
}

/// @title InboundBase
/// @notice Everything a contract needs to RECEIVE: an authenticated delivery, an approval it
///         can hold, and the array that discharges one. Shared by `ReceiverBase`, which is
///         one owner's account, and `TransceiverBase`, which is the shared contract that
///         stands accounts up.
///
/// @dev THE TWO INHERITORS ARE HERE FOR THE SAME REASON AND USE IT DIFFERENTLY. An account
///      receives its owner's payloads. A transceiver receives bootstraps, and a bootstrap is
///      the one message in the protocol whose gas cost lands on whoever happens to be
///      delivering it: a payload that arrives as `commit(hash)` can be finalized later by
///      anyone willing to pay for it, which is why the transceiver needs the same machinery
///      rather than a second copy of it.
///
/// @dev `cancel` IS HERE AS PLUMBING, NOT AS AN ENTRY POINT. `_cancel` removes every copy of
///      an approval and each inheritor exposes it behind its own gate: an account answers to
///      its transmitter, a transceiver to a payload it is already executing. The gate is the
///      whole question, because a transceiver is shared by every owner on its chain and an
///      openly reachable cancel there would let whoever found it strip a bootstrap somebody
///      else has already paid to send. Without ANY cancel, an approved bootstrap could never
///      be withdrawn: it would sit indefinitely with the timing of its execution — and so the
///      state its payload runs against — belonging to whoever chose to finalize it.
///
/// @dev EXECUTION IS UNORDERED, and `_commitments` is a count rather than a set: see the
///      storage comment below. Both properties are the same on either inheritor, which is
///      most of the argument for the base existing at all.
abstract contract InboundBase is
    Executor,
    Roles,
    ReentrancyGuardUpgradeable,
    ICommitFinalize,
    IERC7786Recipient
{
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;

    /// @notice The outstanding approvals: commitment => how many times it may still be
    ///         finalized.
    ///
    /// @dev A MAP RATHER THAN A QUEUE, WHICH IS WHAT MAKES EXECUTION UNORDERED. Approvals
    ///      have no positions, so `finalize` takes whichever array it is handed and discharges
    ///      THAT approval: a payload waiting on a slow relayer does not block the ones
    ///      approved after it. What it gives up is the guarantee that approvals land in the
    ///      order they were made — a relayer holding two valid arrays chooses.
    ///
    /// @dev THE VALUE IS A COUNT, BECAUSE A HASH IS NOT AN IDENTITY. Two identical payloads
    ///      are two separate approvals, and a set would silently collapse them into one:
    ///      approving the same transfer twice would buy one. Each `finalize` decrements, and
    ///      the entry leaves the map at zero.
    ///
    /// @dev ENUMERABLE BECAUSE "WHAT IS OUTSTANDING" HAS TO BE ANSWERABLE ON-CHAIN, and with
    ///      no ordering there is no head to read instead.
    EnumerableMap.Bytes32ToUintMap private _commitments;

    event Committed(bytes32 indexed commitment, uint256 outstanding);
    event Finalized(bytes32 indexed commitment, uint256 remaining, uint256 callCount);
    /// @dev A payload that arrived over the wire and ran on arrival, as distinct from one a
    ///      commitment discharged or a gated entry point drove locally. A monitor that cannot
    ///      tell those apart cannot audit any of them.
    event Delivered(uint256 callCount);
    /// @dev Carries what was dropped, since cancelling removes every outstanding copy.
    event Cancelled(bytes32 indexed commitment, uint256 dropped);

    /// @dev No approval matches the array supplied, which covers both "nothing is
    ///      outstanding" and "something is, but not this".
    error CommitmentMismatch();
    /// @dev Nothing outstanding under that hash, so there is nothing to withdraw. Refused
    ///      rather than treated as a no-op, because reporting success would suggest a payload
    ///      had been stopped when it may already have run.
    error NotCommitted(bytes32 commitment);
    /// @dev Zero would make "committed" indistinguishable from "never committed".
    error ZeroCommitment();
    error EmptyBatch();
    /// @dev The message did not come from the origin this contract accepts messages from.
    error UnauthenticatedSender(bytes sender);

    /* ================================== approving =============================== */

    /// @notice Who may approve a hash here. Declared, not implemented: an account answers
    ///         "its transmitter, or a payload it is already executing", a transceiver answers
    ///         "a payload it is already executing" and nothing else.
    /// @dev IT IS THE ONE THING THE TWO INHERITORS GENUINELY DISAGREE ABOUT, which is why it
    ///      is the seam. Everything else below is identical on both.
    function _checkCommitter() internal view virtual;

    /// @notice Approve the hash of a call array, to be executed later by anyone.
    /// @dev The same hash may be approved twice: two identical payloads are two separate
    ///      approvals, and each needs its own `finalize`. That is what the count is for.
    /// @return approvals How many times this hash may now be finalized.
    function commit(bytes32 commitment_)
        external
        virtual
        override
        returns (uint256 approvals)
    {
        _checkCommitter();
        if (commitment_ == bytes32(0)) revert ZeroCommitment();

        (, uint256 held) = _commitments.tryGet(commitment_);
        approvals = held + 1;
        _commitments.set(commitment_, approvals);
        emit Committed(commitment_, approvals);
    }

    /* ================================= finalizing =============================== */

    /// @notice Supply an approved array, and run it.
    ///
    /// @dev NOT GATED ON A CALLER, deliberately: only an array matching an outstanding
    ///      commitment does anything, which is the point of approving a hash instead of
    ///      trusting a caller. It is also what lets a third party pay the gas for a payload
    ///      the approver could not afford to land itself.
    ///
    /// @dev IT DISCHARGES THE APPROVAL THE ARRAY MATCHES, NOT AN OLDEST ONE. The array names
    ///      its own approval by hashing to it, so nothing has to be in order and nothing can
    ///      block.
    ///
    /// @dev THE COMMITMENT MAY HAVE BEEN BUILT IN EITHER FORM. `Commitment` hashes `Call[]`
    ///      and the equivalent opaque elements to one value, so an approval made over
    ///      `bytes[]` off-chain is discharged by the typed array here.
    function finalize(Call[] calldata calls) external virtual override nonReentrant {
        _finalize(calls);
    }

    /// @notice Discharge several approvals in one transaction, in the order given.
    /// @dev ALL OR NOTHING, because each entry is decremented before its payload runs: a
    ///      prefix standing would discharge approvals whose payloads never completed.
    function finalize(Call[][] calldata batches) external virtual override nonReentrant {
        uint256 n = batches.length;
        if (n == 0) revert EmptyBatch();
        for (uint256 i; i < n; ++i) {
            _finalize(batches[i]);
        }
    }

    /// @dev `Commitment.hashCalls` folds in `ChainKey.local()`, so the chain-binding travels
    ///      with the check: an array approved for another chain hashes to a value this map
    ///      does not hold.
    ///
    /// @dev IT DECREMENTS BEFORE `_execute` RUNS, so a re-entrant `finalize` supplying the
    ///      same array finds that copy of the approval already spent.
    function _finalize(Call[] calldata calls) private {
        bytes32 pending = Commitment.hashCalls(calls);

        (bool held, uint256 approvals) = _commitments.tryGet(pending);
        if (!held) revert CommitmentMismatch();

        uint256 remaining = approvals - 1;
        if (remaining == 0) {
            _commitments.remove(pending);
        } else {
            _commitments.set(pending, remaining);
        }

        emit Finalized(pending, remaining, calls.length);
        _execute(calls);
    }

    /// @notice Withdraw an approval so it can never be finalized.
    ///
    /// @dev IT ZEROES THE ENTRY, NOT ONE COPY OF IT. A hash approved three times is dropped
    ///      three times over, because cancelling is what a party reaches for when a payload
    ///      turns out to be wrong, and a payload that is wrong is wrong in every copy.
    ///      Re-approving is one `commit` away if only some were meant to go.
    ///
    /// @dev IT NAMES THE APPROVAL ITSELF, WHICH IS THE ONLY HANDLE THERE IS. Positions went
    ///      with the queue, and a hash cannot go stale the way an index could: the value a
    ///      caller passes is the value removed, so cancelling the wrong approval requires
    ///      naming the wrong approval.
    ///
    /// @dev Internal, so it is reachable only through the gate an inheritor puts in front of
    ///      it. See the contract note for why that gate is the whole question.
    function _cancel(bytes32 commitment_) internal {
        (bool held, uint256 dropped) = _commitments.tryGet(commitment_);
        if (!held) revert NotCommitted(commitment_);

        _commitments.remove(commitment_);
        emit Cancelled(commitment_, dropped);
    }

    /* ============================== approval reads ============================== */

    /// @notice How many times `commitment_` may still be finalized. Zero means never.
    function outstanding(bytes32 commitment_) public view returns (uint256) {
        (, uint256 held) = _commitments.tryGet(commitment_);
        return held;
    }

    /// @notice Whether `commitment_` has an approval left.
    function isCommitted(bytes32 commitment_) public view returns (bool) {
        return _commitments.contains(commitment_);
    }

    /// @notice Every outstanding approval, which is what a party reviewing what has been
    ///         approved actually wants.
    /// @dev THE ORDER IS NOT STABLE AND MEANS NOTHING. Discharging one swaps the last entry
    ///      into its place, and nothing executes by position anyway.
    function commitments() external view returns (bytes32[] memory hashes) {
        uint256 n = _commitments.length();
        hashes = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            (hashes[i],) = _commitments.at(i);
        }
    }

    /// @notice How many distinct approvals are outstanding.
    /// @dev DISTINCT, not total: a hash approved twice counts once here and twice in
    ///      `outstanding`.
    function pendingCount() external view returns (uint256) {
        return _commitments.length();
    }

    /* ================================== delivery ================================ */

    /// @notice Which origins this contract accepts a delivery from. Declared, not
    ///         implemented: an account answers "my transmitter", a transceiver answers "the
    ///         counterpart on the chain this came from".
    function _authenticateSender(bytes calldata sender) internal view virtual;

    /// @notice ERC-7786 delivery: the gateway hands over an authenticated message.
    ///
    /// @dev THE TWO CHECKS ARE NOT THE SAME CHECK, AND BOTH ARE REQUIRED. This is `external`,
    ///      so without them anyone could hand this contract a payload and have it executed.
    ///      The gateway check says the message came through transport this contract trusts;
    ///      `_authenticateSender` says it came from the one origin allowed to send.
    ///
    /// @dev THE `receiveId` IS DELIBERATELY IGNORED. ERC-7786 offers it for correlation, and
    ///      this protocol needs none: a payload either matches an outstanding commitment or
    ///      executes on arrival, and neither asks which message carried it. Replay is the
    ///      transport's to prevent; see the provider spec.
    function receiveMessage(bytes32, bytes calldata sender, bytes calldata payload)
        external
        payable
        virtual
        override
        onlyRole(GATEWAY_ROLE)
        returns (bytes4)
    {
        _authenticateSender(sender);
        _onMessage(payload);
        return IERC7786Recipient.receiveMessage.selector;
    }

    /// @notice Run a payload that arrived over the wire.
    ///
    /// @dev THE INBOUND FUNNEL, and the binding does not decode: every provider gets the same
    ///      decoder and the same failure mode. Execution runs INSIDE the delivery callback,
    ///      so a reverting payload fails the message rather than stranding anything, and
    ///      every provider lets anyone re-execute a failed message, which makes it a retry
    ///      rather than a loss.
    ///
    /// @dev A PAYLOAD THAT SHOULD WAIT SAYS SO ITSELF, by carrying one element targeting this
    ///      contract's own `commit`. Nothing on the wire distinguishes it from any other
    ///      payload, which is why there is no message-type tag anywhere in the protocol.
    ///
    /// @dev `nonReentrant`, shared with `finalize`. Execution calls arbitrary targets from
    ///      inside a provider callback, which is a surface a purely local path would not have.
    function _onMessage(bytes calldata payload) internal virtual nonReentrant {
        Call[] memory calls = Payload.decodeCalls(payload);
        emit Delivered(calls.length);
        _execute(calls);
    }

    /// @notice The address half of an ERC-7930 sender envelope, or a revert.
    /// @dev Shared so both inheritors narrow the sender the same way. A sender that is not 20
    ///      bytes is not an EVM address and cannot be what either of them expects.
    function _senderAddress(bytes calldata sender) internal pure returns (address) {
        Erc7930.Interop memory io = Erc7930.parseStrict(sender);
        if (io.addr.length != 20) revert UnauthenticatedSender(sender);
        return address(bytes20(io.addr));
    }
}
