// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICrossecuteGuard, SignedSafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {GuardDiscovery} from "@crossecute/safe-guard/GuardDiscovery.sol";
import {SafeSignaturesUtils} from "src/messaging/signed/SafeSignaturesUtils.sol";
import {NestedSafeApproval} from "src/messaging/signed/types/SignedDispatchTypes.sol";

/// @notice Source-side collection of the nested approval evidence a signature blob needs, under
///         the Safes' live thresholds.
/// @dev Checks format, not signers: the Safe checked the signatures when it executed, and
///      `relayLeaf` calls `checkSignatures` for a registration it did not execute. `v = 1` is
///      refused at every level, since no receiver can check it.
library NestedApprovalCollector {
    // getThreshold()
    bytes4 private constant GET_THRESHOLD = 0xe75235b8;

    error NotASafe(address safe);

    /// @dev The receiver cannot read source guard storage, so empty nested signatures travel with
    ///      their signed approval evidence. A missing approval reverts; signers are checked elsewhere.
    function collect(address safe, bytes32 dataHash, bytes memory signatures)
        internal
        view
        returns (NestedSafeApproval[] memory approvals)
    {
        approvals = _walk(safe, dataHash, signatures, new NestedSafeApproval[](0));
    }

    /// @dev The live threshold selects the entries Safe actually checks, so unused trailing bytes
    ///      add no requirement.
    function _walk(address safe, bytes32 dataHash, bytes memory signatures, NestedSafeApproval[] memory approvals)
        private
        view
        returns (NestedSafeApproval[] memory)
    {
        uint256 threshold = _threshold(safe);
        SafeSignaturesUtils.requireLength(safe, signatures, threshold);
        for (uint256 i; i < threshold; ++i) {
            approvals = _entry(safe, dataHash, signatures, i, threshold, approvals);
        }
        return approvals;
    }

    /// @dev Only nested Safes can need approval evidence. The encoded child is a claim, not proof of
    ///      membership or authorization.
    function _entry(
        address safe,
        bytes32 dataHash,
        bytes memory signatures,
        uint256 index,
        uint256 threshold,
        NestedSafeApproval[] memory approvals
    ) private view returns (NestedSafeApproval[] memory) {
        (bytes32 r, bytes32 s, uint8 v) = SafeSignaturesUtils.entry(safe, signatures, index);
        if (v != 0) return approvals;
        return _nested(
            SafeSignaturesUtils.contractOwner(r),
            dataHash,
            SafeSignaturesUtils.extractContractSignature(safe, signatures, uint256(s), threshold),
            approvals
        );
    }

    function _nested(address child, bytes32 parentHash, bytes memory payload, NestedSafeApproval[] memory approvals)
        private
        view
        returns (NestedSafeApproval[] memory)
    {
        bytes32 messageHash = SafeSignaturesUtils.nestedHash(parentHash, child, block.chainid);
        if (payload.length != 0) return _walk(child, messageHash, payload, approvals);

        SignedSafeTx memory approval;
        (approval, approvals) = _approval(approvals, child, messageHash);
        bytes32 approvalHash = SafeSignaturesUtils.approvalHash(child, parentHash, approval.safeTx, block.chainid);
        return _walk(child, approvalHash, approval.signatures, approvals);
    }

    /// @dev Deduplicates by child and message hash; the guard read rejects an empty entry with no
    ///      cached approval.
    function _approval(NestedSafeApproval[] memory approvals, address child, bytes32 messageHash)
        private
        view
        returns (SignedSafeTx memory, NestedSafeApproval[] memory)
    {
        uint256 found = SafeSignaturesUtils.indexOfApproval(approvals, child, messageHash);
        if (found != approvals.length) return (approvals[found].approval, approvals);
        // forge-lint: disable-next-line(calls-loop) a memory allocation, not a call
        NestedSafeApproval[] memory expandedApprovals = new NestedSafeApproval[](approvals.length + 1);
        for (uint256 i; i < approvals.length; ++i) {
            expandedApprovals[i] = approvals[i];
        }
        SignedSafeTx memory approval =
        // forge-lint: disable-next-line(calls-loop) one guard read per nested approval the signatures need
        ICrossecuteGuard(GuardDiscovery.transactionGuard(child)).getApproval(child, messageHash);
        expandedApprovals[approvals.length] = NestedSafeApproval(child, messageHash, approval);
        return (approval, expandedApprovals);
    }

    function _threshold(address safe) private view returns (uint256) {
        // forge-lint: disable-next-line(calls-loop) one threshold read per Safe the signatures name
        (bool ok, bytes memory reply) = safe.staticcall(abi.encodeWithSelector(GET_THRESHOLD));
        if (!ok || reply.length < 32) revert NotASafe(safe);
        return abi.decode(reply, (uint256));
    }
}
