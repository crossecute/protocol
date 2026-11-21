// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SignedSafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {NestedOwnerManagerLib} from "src/messaging/signed/NestedOwnerManagerLib.sol";
import {SafeSignaturesUtils} from "src/messaging/signed/SafeSignaturesUtils.sol";
import {OWNER_EOA, OWNER_SAFE} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {NestedSafeApproval} from "src/messaging/signed/types/SignedDispatchTypes.sol";

/// @notice Where a quorum check reads each Safe's threshold and owners.
/// @dev `open` resolves a Safe to an opaque handle for its owner set and its threshold, zero
///      for a Safe it does not know. `isOwner` answers whether `signer` is in that set with
///      exactly `kind`. `chainId` is the chain the Safes live on, which every Safe domain is
///      computed for.
struct OwnerSource {
    bytes32 context;
    uint256 chainId;
    function(bytes32, address) view returns (bytes32, uint256) open;
    function(bytes32, address, uint8) view returns (bool) isOwner;
}

/// @notice Verifying Safe 1.5.0 signature blobs against an authenticated owner source, without
///         calling any Safe.
///
/// @dev Reproduces `Safe.checkNSignatures` with no executor for the first Safe, and
///      `CompatibilityFallbackHandler.isValidSignature(bytes32,bytes)` for each nested Safe.
///      Two things Safe accepts are refused: `v = 1`, and an empty nested signature without the
///      child's own signed `signMessage` transaction as evidence, verified against the child's
///      own quorum. Only children an entry names are traversed. The walk ends whatever the
///      owner source holds: an inline level reads a strictly shorter slice, and an approval
///      level needs an approval for a hash derived from the one above it.
library SafeQuorum {
    /// @dev The owner source has no threshold for `safe`. A zero threshold never passes as an
    ///      empty quorum.
    error UnknownSafe(address safe);
    /// @dev Not an owner of `safe`, or an owner of the other kind.
    error NotAnOwner(address safe, address signer);
    error SignersNotAscending(address safe);
    error MissingNestedSafeApproval(address childSafe, bytes32 messageHash);
    error DuplicateNestedSafeApproval(address childSafe, bytes32 messageHash);

    /// @notice Require a valid quorum of `safe` over `dataHash`, including any nested approvals.
    /// @dev Duplicate child/message approvals revert; unused approvals are ignored.
    function requireQuorum(
        OwnerSource memory source,
        address safe,
        bytes32 dataHash,
        bytes memory signatures,
        NestedSafeApproval[] memory approvals
    ) internal view {
        for (uint256 i = 1; i < approvals.length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (
                    approvals[i].childSafe == approvals[j].childSafe
                        && approvals[i].messageHash == approvals[j].messageHash
                ) revert DuplicateNestedSafeApproval(approvals[i].childSafe, approvals[i].messageHash);
            }
        }
        _requireSignatures(source, safe, dataHash, signatures, approvals);
    }

    /// @dev Strictly ascending signers stop a repeated signer counting twice.
    function _requireSignatures(
        OwnerSource memory source,
        address safe,
        bytes32 dataHash,
        bytes memory signatures,
        NestedSafeApproval[] memory approvals
    ) private view {
        (bytes32 owners, uint256 threshold) = source.open(source.context, safe);
        if (threshold == 0) revert UnknownSafe(safe);
        SafeSignaturesUtils.requireLength(safe, signatures, threshold);

        // Safe's own floor, which also keeps the list sentinel out.
        address last = NestedOwnerManagerLib.SENTINEL;
        for (uint256 i; i < threshold; ++i) {
            address signer = _signer(source, safe, owners, dataHash, signatures, i, threshold, approvals);
            if (signer <= last) revert SignersNotAscending(safe);
            last = signer;
        }
    }

    /// @dev The owner must be in the Safe's set with the matching kind, so an EOA-kind owner never
    ///      counts through a contract signature, and a child counts only after its own quorum verifies.
    function _signer(
        OwnerSource memory source,
        address safe,
        bytes32 owners,
        bytes32 dataHash,
        bytes memory signatures,
        uint256 index,
        uint256 threshold,
        NestedSafeApproval[] memory approvals
    ) private view returns (address signer) {
        (bytes32 r, bytes32 s, uint8 v) = SafeSignaturesUtils.entry(safe, signatures, index);
        if (v != 0) {
            signer = SafeSignaturesUtils.recover(dataHash, r, s, v);
            if (!source.isOwner(owners, signer, OWNER_EOA)) revert NotAnOwner(safe, signer);
            return signer;
        }
        signer = SafeSignaturesUtils.contractOwner(r);
        if (!source.isOwner(owners, signer, OWNER_SAFE)) revert NotAnOwner(safe, signer);
        _requireNested(
            source,
            signer,
            dataHash,
            SafeSignaturesUtils.extractContractSignature(safe, signatures, uint256(s), threshold),
            approvals
        );
    }

    /// @dev Binding to the child and source-chain domain proves the child authorized this parent
    ///      hash without calling a destination copy of the Safe.
    function _requireNested(
        OwnerSource memory source,
        address child,
        bytes32 parentHash,
        bytes memory signatures,
        NestedSafeApproval[] memory approvals
    ) private view {
        uint256 chainId = source.chainId;
        bytes32 messageHash = SafeSignaturesUtils.nestedHash(parentHash, child, chainId);
        if (signatures.length != 0) {
            _requireSignatures(source, child, messageHash, signatures, approvals);
            return;
        }
        uint256 found = SafeSignaturesUtils.indexOfApproval(approvals, child, messageHash);
        if (found == approvals.length) revert MissingNestedSafeApproval(child, messageHash);
        SignedSafeTx memory approval = approvals[found].approval;
        _requireSignatures(
            source,
            child,
            SafeSignaturesUtils.approvalHash(child, parentHash, approval.safeTx, chainId),
            approval.signatures,
            approvals
        );
    }
}
