// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title MessagingContext
/// @notice Roles, modifiers, and errors shared by both halves of the messaging stack.
///
/// @dev These errors live here because a Transceiver inherits BOTH `TransceiverBase` and
///      `ReceiverBase`. Declaring `CommitmentMismatch` in each would be a duplicate
///      identifier in the derived contract, so the commit/finalize vocabulary is
///      declared once and inherited by both.
abstract contract MessagingContext {
    /// @dev No commitment is pending for this caller.
    error NothingCommitted();
    /// @dev The supplied calls do not hash to the pending commitment.
    error CommitmentMismatch();
    /// @dev A commitment of zero is indistinguishable from "nothing pending", and from a
    ///      cancelled queue entry.
    error ZeroCommitment();
}
