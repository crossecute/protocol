// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICrossecuteGuard, SignedSafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {GuardDiscovery} from "@crossecute/safe-guard/GuardDiscovery.sol";
import {SafeSignatures} from "src/messaging/signed/SafeSignatures.sol";
import {NestedApproval} from "src/messaging/signed/ISignedDispatch.sol";

/// @notice Source-side collection of the nested approval evidence a signature blob needs, under
///         the Safes' live thresholds.
/// @dev Checks format, not signers: the Safe checked the signatures when it executed, and
///      `relayLeaf` calls `checkSignatures` for a registration it did not execute. `v = 1` is
///      refused at every level, since no receiver can check it.
library SafeEvidence {
    // getThreshold()
    bytes4 private constant GET_THRESHOLD = 0xe75235b8;

    error NotASafe(address safe);

    /// @notice The approvals `SafeAuthority.verify` needs for `signatures` over `dataHash` by
    ///         `safe` on this chain, read from each child's current transaction guard. Reverts if
    ///         a guard holds none for an empty nested signature.
    function collect(address safe, bytes32 dataHash, bytes memory signatures)
        internal
        view
        returns (NestedApproval[] memory approvals)
    {
        approvals = _walk(safe, dataHash, signatures, new NestedApproval[](0));
    }

    function _walk(address safe, bytes32 dataHash, bytes memory signatures, NestedApproval[] memory approvals)
        private
        view
        returns (NestedApproval[] memory)
    {
        uint256 threshold = _threshold(safe);
        SafeSignatures.requireLength(safe, signatures, threshold);
        for (uint256 i; i < threshold; ++i) {
            approvals = _entry(safe, dataHash, signatures, i, threshold, approvals);
        }
        return approvals;
    }

    /// @dev Entry `index`: nothing to collect for an ECDSA entry; recursion into a nested Safe's
    ///      inline signatures or into the approval standing in for empty ones.
    function _entry(
        address safe,
        bytes32 dataHash,
        bytes memory signatures,
        uint256 index,
        uint256 threshold,
        NestedApproval[] memory approvals
    ) private view returns (NestedApproval[] memory) {
        (bytes32 r, bytes32 s, uint8 v) = SafeSignatures.entry(safe, signatures, index);
        if (v != 0) return approvals;
        // forge-lint: disable-next-line(unsafe-typecast) Safe reads the owner the same way
        address child = address(uint160(uint256(r)));
        return
            _nested(
                child, dataHash, SafeSignatures.contractSignature(safe, signatures, uint256(s), threshold), approvals
            );
    }

    function _nested(address child, bytes32 parentHash, bytes memory payload, NestedApproval[] memory approvals)
        private
        view
        returns (NestedApproval[] memory)
    {
        bytes32 messageHash = SafeSignatures.nestedHash(parentHash, child, block.chainid);
        if (payload.length != 0) return _walk(child, messageHash, payload, approvals);

        SignedSafeTx memory approval;
        (approval, approvals) = _approval(approvals, child, messageHash);
        bytes32 approvalHash = SafeSignatures.approvalHash(child, parentHash, approval.safeTx, block.chainid);
        return _walk(child, approvalHash, approval.signatures, approvals);
    }

    /// @dev The entry already collected for `(child, messageHash)`, or the guard's, appended.
    function _approval(NestedApproval[] memory approvals, address child, bytes32 messageHash)
        private
        view
        returns (SignedSafeTx memory, NestedApproval[] memory)
    {
        for (uint256 i; i < approvals.length; ++i) {
            if (approvals[i].childSafe == child && approvals[i].messageHash == messageHash) {
                return (approvals[i].approval, approvals);
            }
        }
        // forge-lint: disable-next-line(calls-loop) a memory allocation, not a call
        NestedApproval[] memory grown = new NestedApproval[](approvals.length + 1);
        for (uint256 i; i < approvals.length; ++i) {
            grown[i] = approvals[i];
        }
        SignedSafeTx memory approval =
        // forge-lint: disable-next-line(calls-loop) one guard read per nested approval the signatures need
        ICrossecuteGuard(GuardDiscovery.transactionGuard(child)).getApproval(child, messageHash);
        grown[approvals.length] = NestedApproval(child, messageHash, approval);
        return (approval, grown);
    }

    function _threshold(address safe) private view returns (uint256) {
        // forge-lint: disable-next-line(calls-loop) one threshold read per Safe the signatures name
        (bool ok, bytes memory reply) = safe.staticcall(abi.encodeWithSelector(GET_THRESHOLD));
        if (!ok || reply.length < 32) revert NotASafe(safe);
        return abi.decode(reply, (uint256));
    }
}
