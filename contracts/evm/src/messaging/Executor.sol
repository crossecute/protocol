// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";

/// @title Executor
/// @notice Running a verified call array, and the policy that gates it.
/// @dev Shared by every contract that runs payloads: a receiver runs what arrives, a
///      transmitter what its owner hands it, and a transceiver the calls its `isAllowed`
///      admits. No storage.
abstract contract Executor {
    error SelectorNotAllowed(address target, bytes4 selector);
    /// @dev Carries the index of the element that failed.
    error CallFailed(uint256 index, bytes reason);
    /// @dev An empty array proves no intent, so it is refused rather than a successful no-op.
    error EmptyExecution();

    /// @notice Call policy. The default allows everything.
    ///
    /// @dev Open by default: accounts are full-power and answer to one owner, like a Safe, and
    ///      anything that can deliver an authorized payload could forge a commitment as easily
    ///      as a call. Failing closed would revert every payload, the bootstrap payload
    ///      included, until overridden. A transceiver overrides it.
    ///
    /// @dev Merkle-verified calls are not in v1. If added, the model is Veda's
    ///      `ManagerWithMerkleVerification`:
    ///      https://github.com/Veda-Labs/boring-vault/blob/main/src/base/Roles/ManagerWithMerkleVerification.sol
    function isAllowed(address, bytes4) public view virtual returns (bool) {
        return true;
    }

    /// @notice Run the verified calls, in order, all or nothing.
    /// @dev An approval covers the array as a unit, so a prefix must not stand. The failing
    ///      call's revert reason is carried in `CallFailed`.
    function _execute(Call[] memory calls) internal virtual {
        uint256 len = calls.length;
        for (uint256 i; i < len; ++i) {
            Call memory c = calls[i];

            // Under four bytes there is no selector (a value transfer or a fallback hit).
            // `bytes4` of short data right-pads with zeros and would invent one.
            // forge-lint: disable-next-line(unsafe-typecast) the first 4 bytes; length checked
            bytes4 selector = c.data.length >= 4 ? bytes4(c.data) : bytes4(0);
            if (!isAllowed(c.target, selector)) {
                revert SelectorNotAllowed(c.target, selector);
            }

            // forge-lint: disable-next-line(arbitrary-send-eth,calls-loop) owner-approved calls, all or nothing
            (bool ok, bytes memory reason) = c.target.call{value: c.value}(c.data);
            if (!ok) revert CallFailed(i, reason);
        }
    }
}
