// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MessagingContext} from "src/messaging/MessagingContext.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Call} from "src/messaging/Call.sol";

/// @title InboundBase
/// @notice The receiving half: the two rules a commitment obeys, with no opinion about
///         where it is stored or who may store it.
///
/// @dev THE MIRROR OF `OutboundBase`, AND SPLIT FOR THE SAME REASON. The verification
///      step needs one implementation rather than two that drift — but sharing it through
///      inheritance would force a shared storage shape, and the two sides do not have one.
///      A receiver holds a queue of approvals; a transceiver holds none at all.
///
///      What is genuinely common is not the storage. It is the two rules: an approval may
///      never be zero, and it is discharged only by an array that hashes to it. Both are
///      stated here against a `bytes32` passed in, so each side keeps whatever storage its
///      cardinality demands and there is still exactly one implementation of each rule.
///
/// @dev NO STORAGE HERE EITHER, so `TransceiverBase` can inherit this and `OutboundBase`
///      together without a layout question.
abstract contract InboundBase is MessagingContext {
    /// @notice The discharge rule: only the approved array does anything.
    ///
    /// @dev THE CHAIN-BINDING TRAVELS WITH THE CHECK, NOT WITH THE CALLER.
    ///      `Commitment.isHashedCall` folds in `ChainKey.local()`, so wherever this runs it
    ///      binds to the chain it runs on. Receivers sit at deterministic addresses across
    ///      chains, which is exactly where a cross-chain replay would otherwise work.
    /// @dev THE APPROVAL MAY HAVE BEEN BUILT IN EITHER FORM. `Commitment` hashes `Call[]`
    ///      and the equivalent opaque elements to one value, so a commitment computed
    ///      off-chain over `bytes[]` — the canonical, VM-agnostic form — is discharged by
    ///      the typed array supplied here. The commitment approves the calls, not the
    ///      serialization somebody chose to deliver them in.
    function _requireMatchingCalls(bytes32 pending, Call[] memory calls) internal view {
        if (pending == bytes32(0)) revert NothingCommitted();
        if (!Commitment.isHashedCall(pending, calls)) revert CommitmentMismatch();
    }

    /// @notice The pinning rule: an approval is never zero.
    ///
    /// @dev ZERO IS THE SENTINEL, WHICH IS THE WHOLE RULE. It marks a cancelled queue
    ///      entry and an absent one, so accepting it as an approval would create a record
    ///      that every reader treats as not there.
    ///
    /// @dev THERE IS NO "ONE LIVE APPROVAL" RULE, because approvals are a queue: a second
    ///      commit appends rather than replacing, so there is nothing to overwrite and
    ///      nothing to protect. Refusing a duplicate would be wrong on its own terms too —
    ///      two identical payloads are two separate approvals, and each needs its own
    ///      `finalize`.
    function _requireCommittable(bytes32 incoming) internal pure {
        if (incoming == bytes32(0)) revert ZeroCommitment();
    }
}
