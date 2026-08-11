// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";

/// @title Executor
/// @notice Running a verified call array, and the policy that gates it.
///
/// @dev SHARED BECAUSE BOTH ENDS RUN PAYLOADS. A receiver runs what arrives over a bridge, a
///      transmitter what its owner hands it locally; those differ in how the payload was
///      authorized and in nothing else, so the loop, the policy check, and the
///      all-or-nothing rule are stated once rather than twice with a chance to drift.
///
/// @dev A TRANSCEIVER DELIBERATELY DOES NOT INHERIT THIS. It has no payload of its own, and
///      keeping the capability out of its inheritance makes that structural rather than a
///      promise not to call something.
///
/// @dev NO STORAGE, so it mixes into a contract that already has a layout.
abstract contract Executor {
    error SelectorNotAllowed(address target, bytes4 selector);
    /// @dev Carries the index because the array is approved as a unit: knowing WHICH element
    ///      failed is the difference between a diagnosable payload and a rejected one.
    error CallFailed(uint256 index, bytes reason);
    /// @dev An empty array has no commitment to prove intent, so it is refused rather than
    ///      treated as a successful no-op.
    error EmptyExecution();

    /// @notice Call policy. The default allows everything.
    ///
    /// @dev OPEN BY DEFAULT, AND NOT A MISSING CHECK. These accounts are full-power and
    ///      answer to one owner, the same way a Safe does: anything that can deliver an
    ///      authorized payload can already make one do anything, and a compromised bridge
    ///      could forge a commitment hash as easily as a call array. So `(target, selector)`
    ///      was never what stood between a forged message and execution. Failing closed would
    ///      only revert every payload until a protocol overrode it, the bootstrap payload
    ///      inside `initialize` included.
    ///
    /// @dev MERKLE-VERIFIED CALLS REMAIN THE PLAN, as an opt-in. Follow Veda's
    ///      `ManagerWithMerkleVerification`: a root of permitted leaves binds target,
    ///      selector, and the argument constraints that matter, each call supplying a proof.
    ///      That moves the policy from "which functions" to "which exact operations", and
    ///      makes the permitted set one root signers approve and rotate.
    ///      https://github.com/Veda-Labs/boring-vault/blob/main/src/base/Roles/ManagerWithMerkleVerification.sol
    function isAllowed(address, bytes4) public view virtual returns (bool) {
        return true;
    }

    /// @notice Run the verified calls, in order, all or nothing.
    ///
    /// @dev ONE FAILURE REVERTS EVERYTHING. An approval covers the array as a unit and a
    ///      caller may already have consumed it, so executing a prefix would discharge an
    ///      approval that was never satisfied, and do it unrepeatably. The original revert
    ///      reason is carried out in `CallFailed` rather than swallowed.
    ///
    /// @dev `virtual` so a protocol can wrap it, but CONCRETE so one that does not override
    ///      still executes and still checks its policy. An empty body would mean a payload
    ///      was verified perfectly and then silently did nothing.
    function _execute(Call[] memory calls) internal virtual {
        uint256 len = calls.length;
        for (uint256 i; i < len; ++i) {
            Call memory c = calls[i];

            // Under four bytes there is no selector: a bare value transfer, or a hit on the
            // fallback. `bytes4` of a short `bytes` right-pads with zeros, so reading one
            // anyway would invent a selector the payload never named, and one that could
            // match a policy entry by accident.
            bytes4 selector = c.data.length >= 4 ? bytes4(c.data) : bytes4(0);
            if (!isAllowed(c.target, selector)) {
                revert SelectorNotAllowed(c.target, selector);
            }

            (bool ok, bytes memory reason) = c.target.call{value: c.value}(c.data);
            if (!ok) revert CallFailed(i, reason);
        }
    }
}
