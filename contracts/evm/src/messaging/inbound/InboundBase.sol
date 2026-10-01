// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Call} from "src/messaging/Call.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Executor} from "src/messaging/Executor.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Roles} from "src/messaging/Roles.sol";
import {IERC7786Recipient} from "src/messaging/IErc7786.sol";

/// @notice Two-step execution: approve a hash now, supply the matching array later.
/// @dev `commit` is gated and `finalize` is not: only an array matching an approved hash does
///      anything, so whoever relays it is irrelevant.
interface ICommitFinalize {
    function commit(bytes32 commitment) external returns (uint256 approvals);
    function finalize(Call[] calldata calls) external;
    function finalize(Call[][] calldata batches) external;
}

/// @notice Withdrawing an approval.
/// @dev One signature, two gates: an account answers to its transmitter, a transceiver only
///      to a payload it is already executing.
interface ICancel {
    function cancel(bytes32 commitment) external;
}

/// @title InboundBase
/// @notice Everything a contract needs to receive: an authenticated delivery, approvals it can
///         hold, and the arrays that discharge them. Shared by `ReceiverBase` (one owner's
///         account) and `TransceiverBase` (which stands accounts up).
///
/// @dev A transceiver needs the same machinery because a bootstrap's gas lands on whoever
///      delivers it: one that arrives as `commit(hash)` can be finalized later by anyone
///      willing to pay.
///
/// @dev `_cancel` is shared code, not an entry point; each inheritor exposes it behind its own
///      gate. Without any cancel an approved payload could never be withdrawn, and whoever
///      finalized it would choose when it ran.
abstract contract InboundBase is Executor, Roles, ReentrancyGuardUpgradeable, ICommitFinalize, IERC7786Recipient {
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;

    /// @notice The outstanding approvals: commitment => how many times it may still be
    ///         finalized.
    ///
    /// @dev A map, not a queue: `finalize` discharges whichever approval its array hashes to,
    ///      so a payload waiting on a slow relayer blocks nothing after it, and a relayer
    ///      holding two arrays chooses their order.
    ///
    /// @dev A count, not a set: two identical payloads are two approvals. Each `finalize`
    ///      decrements, and the entry leaves the map at zero. Enumerable, so what is
    ///      outstanding can be read on-chain.
    EnumerableMap.Bytes32ToUintMap private _commitments;

    event Committed(bytes32 indexed commitment, uint256 outstanding);
    event Finalized(bytes32 indexed commitment, uint256 remaining, uint256 callCount);
    /// @dev A payload that ran on arrival, as distinct from one a commitment discharged or a
    ///      gated entry point drove locally.
    event Delivered(uint256 callCount);
    /// @dev Carries what was dropped, since cancelling removes every outstanding copy.
    event Cancelled(bytes32 indexed commitment, uint256 dropped);

    /// @dev No approval matches the array supplied.
    error CommitmentMismatch();
    /// @dev Nothing outstanding under that hash. Refused rather than a no-op, since success
    ///      would suggest a payload was stopped that may already have run.
    error NotCommitted(bytes32 commitment);
    /// @dev Zero would make "committed" indistinguishable from "never committed".
    error ZeroCommitment();
    error EmptyBatch();
    /// @dev The message did not come from the origin this contract accepts messages from.
    error UnauthenticatedSender(bytes sender);

    /* ================================== approving =============================== */

    /// @notice Who may approve a hash here: on an account, its transmitter or a payload it is
    ///         executing; on a transceiver, only a payload it is executing.
    function _checkCommitter() internal view virtual;

    /// @notice Approve the hash of a call array, to be executed later by anyone.
    /// @dev The same hash may be approved twice; each approval needs its own `finalize`.
    /// @return approvals How many times this hash may now be finalized.
    function commit(bytes32 commitment_) external virtual override returns (uint256 approvals) {
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
    /// @dev Ungated: only an array matching an outstanding commitment does anything, which lets
    ///      a third party pay the gas. It discharges the approval the array hashes to.
    ///
    /// @dev `Commitment` hashes `Call[]` and the equivalent opaque elements to one value, so an
    ///      approval made over `bytes[]` is discharged by the typed array.
    function finalize(Call[] calldata calls) external virtual override nonReentrant {
        _finalize(calls);
    }

    /// @notice Discharge several approvals in one transaction, in the order given.
    /// @dev All or nothing, since each entry is decremented before its payload runs.
    function finalize(Call[][] calldata batches) external virtual override nonReentrant {
        uint256 n = batches.length;
        if (n == 0) revert EmptyBatch();
        for (uint256 i; i < n; ++i) {
            _finalize(batches[i]);
        }
    }

    /// @dev `Commitment.hashCalls` seeds with `ChainKey.local()`, so an array approved for
    ///      another chain hashes to a value this map does not hold. The decrement happens
    ///      before `_execute`, so a re-entrant `finalize` of the same array finds it spent.
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
    /// @dev Drops every copy: a wrong payload is wrong in every copy, and re-approving is one
    ///      `commit` away. Internal, reachable only through an inheritor's gate.
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

    /// @notice Every outstanding approval.
    /// @dev The order is not stable: discharging one swaps the last entry into its place.
    function commitments() external view returns (bytes32[] memory hashes) {
        uint256 n = _commitments.length();
        hashes = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            (hashes[i],) = _commitments.at(i);
        }
    }

    /// @notice How many distinct approvals are outstanding: a hash approved twice counts once
    ///         here and twice in `outstanding`.
    function pendingCount() external view returns (uint256) {
        return _commitments.length();
    }

    /* ================================== delivery ================================ */

    /// @notice Which origins this contract accepts a delivery from: an account accepts its
    ///         transmitter, a transceiver the counterpart on the chain this came from.
    function _authenticateSender(bytes calldata sender) internal view virtual;

    /// @notice ERC-7786 delivery: the gateway hands over an authenticated message.
    ///
    /// @dev Two checks, both required on an `external` entry point: the gateway role says the
    ///      transport is trusted, `_authenticateSender` says the message came from the one
    ///      origin allowed to send.
    ///
    /// @dev `receiveId` is ignored: nothing here correlates messages, and replay is the
    ///      transport's to prevent (`docs/provider-spec.md` R3.5).
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
    /// @dev Decoded here, not by the binding. It runs inside the delivery callback, so a
    ///      reverting payload fails the message, which every provider lets anyone re-execute.
    ///      A payload that should wait carries a self-call to `commit`; nothing on the wire
    ///      distinguishes it.
    ///
    /// @dev `nonReentrant`, shared with `finalize`, since it calls arbitrary targets from a
    ///      provider callback.
    function _onMessage(bytes calldata payload) internal virtual nonReentrant {
        Call[] memory calls = Payload.decodeCalls(payload);
        emit Delivered(calls.length);
        _execute(calls);
    }

    /// @notice The address half of an ERC-7930 sender envelope; reverts unless it is 20 bytes.
    function _senderAddress(bytes calldata sender) internal pure returns (address) {
        Erc7930.Interop memory io = Erc7930.parseStrict(sender);
        if (io.addr.length != 20) revert UnauthenticatedSender(sender);
        // forge-lint: disable-next-line(unsafe-typecast) length checked above
        return address(bytes20(io.addr));
    }
}
