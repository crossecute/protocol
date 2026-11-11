// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SignedSafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {SafeAuthorityGraph} from "src/messaging/signed/SafeAuthorityGraph.sol";
import {SafeOwnerState, OwnerLink, NestedOwnerManagerLib} from "src/messaging/signed/NestedOwnerManagerLib.sol";
import {SafeSignaturesUtils} from "src/messaging/signed/SafeSignaturesUtils.sol";
import {SafeAuthorityRecord, SafeOwner, OWNER_EOA, OWNER_SAFE} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {NestedSafeApproval} from "src/messaging/signed/types/SignedDispatchTypes.sol";

/// @notice A stored owner graph: one `SafeOwnerState` per source Safe, keyed by its source address.
/// @dev `sourceChainId` is the chain the Safes live on, which every Safe domain is computed for.
struct SafeAuthorityState {
    address root;
    uint256 sourceChainId;
    mapping(address => SafeOwnerState) safes;
}

/// @notice Storing an owner graph and verifying Safe 1.5.0 signature blobs against it, without
///         calling any Safe.
///
/// @dev Reproduces `Safe.checkNSignatures` with no executor for the root, and
///      `CompatibilityFallbackHandler.isValidSignature(bytes32,bytes)` for each nested Safe.
///      Two things Safe accepts are refused: `v = 1`, and an empty nested signature without the
///      child's own signed `signMessage` transaction as evidence, verified against the child's
///      stored quorum. Only children an entry names are traversed.
library SafeAuthority {
    using NestedOwnerManagerLib for SafeOwnerState;

    error UnknownSafe(address safe);
    /// @dev Not an owner of `safe`, or an owner of the other kind.
    error NotAnOwner(address safe, address signer);
    error SignersNotAscending(address safe);
    error MissingNestedSafeApproval(address childSafe, bytes32 messageHash);
    error DuplicateNestedSafeApproval(address childSafe, bytes32 messageHash);

    /// @notice Validate and store the root Safe, source chain and each reachable Safe's owner
    ///         configuration.
    /// @dev The destination needs an authenticated local authority snapshot because the source
    ///      Safes cannot be queried during destination verification.
    function store(SafeAuthorityState storage self, SafeAuthorityRecord[] memory records, uint256 sourceChainId)
        public
    {
        SafeAuthorityGraph.requireCanonical(records);
        self.root = records[0].safe;
        self.sourceChainId = sourceChainId;
        for (uint256 i; i < records.length; ++i) {
            SafeAuthorityRecord memory record = records[i];
            self.safes[record.safe].setupOwners(record.safe, record.owners, record.threshold);
        }
    }

    /// @notice Reconstruct the stored authority graph in canonical order.
    /// @dev Readback lets callers inspect the ownership snapshot and reproduce its commitment
    ///      without relying on source-chain state.
    function readRecords(SafeAuthorityState storage self) public view returns (SafeAuthorityRecord[] memory) {
        bytes32 context;
        assembly ("memory-safe") {
            context := self.slot
        }
        return SafeAuthorityGraph.walk(self.root, context, _loadStored);
    }

    /// @notice Read one Safe's stored owners and threshold through the supplied storage
    ///         context.
    /// @dev This adapts receiver storage to the same graph traversal used for source
    ///      derivation; `context` identifies the authority storage slot.
    function _loadStored(bytes32 context, address safe) private view returns (SafeOwner[] memory, uint256) {
        SafeAuthorityState storage self;
        assembly ("memory-safe") {
            self.slot := context
        }
        SafeOwnerState storage ownerState = self.safes[safe];
        return (ownerState.getOwners(), ownerState.threshold);
    }

    /// @notice Require a valid root-Safe quorum over `dataHash`, including any nested
    ///         approvals.
    /// @dev This is the receiver's authorization check, independent of who delivered the
    ///      message. Duplicate child/message approvals revert; unused approvals are ignored.
    function verify(
        SafeAuthorityState storage self,
        bytes32 dataHash,
        bytes memory signatures,
        NestedSafeApproval[] memory approvals
    ) public view {
        for (uint256 i = 1; i < approvals.length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (
                    approvals[i].childSafe == approvals[j].childSafe
                        && approvals[i].messageHash == approvals[j].messageHash
                ) revert DuplicateNestedSafeApproval(approvals[i].childSafe, approvals[i].messageHash);
            }
        }
        _check(self, self.root, dataHash, signatures, approvals);
    }

    /// @notice Verify the required number of distinct, ascending owners for one Safe.
    /// @dev Threshold enforcement and strict signer ordering prevent an incomplete quorum or
    ///      repeated signer from authorizing a message.
    function _check(
        SafeAuthorityState storage self,
        address safe,
        bytes32 dataHash,
        bytes memory signatures,
        NestedSafeApproval[] memory approvals
    ) private view {
        uint256 threshold = self.safes[safe].threshold;
        if (threshold == 0) revert UnknownSafe(safe);
        SafeSignaturesUtils.requireLength(safe, signatures, threshold);

        // Safe's own floor, which also keeps the list sentinel out.
        address last = NestedOwnerManagerLib.SENTINEL;
        for (uint256 i; i < threshold; ++i) {
            address signer = _signer(self, safe, dataHash, signatures, i, threshold, approvals);
            if (signer <= last) revert SignersNotAscending(safe);
            last = signer;
        }
    }

    /// @notice Recover an EOA or validate a claimed child Safe, then return that owner's
    ///         address.
    /// @dev The owner must exist with the correct stored kind. A child address read from `r`
    ///      counts only after its own quorum is recursively verified.
    function _signer(
        SafeAuthorityState storage self,
        address safe,
        bytes32 dataHash,
        bytes memory signatures,
        uint256 index,
        uint256 threshold,
        NestedSafeApproval[] memory approvals
    ) private view returns (address signer) {
        (bytes32 r, bytes32 s, uint8 v) = SafeSignaturesUtils.entry(safe, signatures, index);
        if (v != 0) {
            signer = SafeSignaturesUtils.recover(dataHash, r, s, v);
            _requireOwner(self.safes[safe], safe, signer, OWNER_EOA);
            return signer;
        }
        // forge-lint: disable-next-line(unsafe-typecast) Safe reads the owner the same way
        signer = address(uint160(uint256(r)));
        _requireOwner(self.safes[safe], safe, signer, OWNER_SAFE);
        _checkNested(
            self,
            signer,
            dataHash,
            SafeSignaturesUtils.extractContractSignature(safe, signatures, uint256(s), threshold),
            approvals
        );
    }

    /// @notice Require an address to be a real stored owner of the expected kind.
    /// @dev Signature recovery or a claimed child address alone does not establish authority,
    ///      and the linked-list sentinel must never count as an owner.
    function _requireOwner(SafeOwnerState storage ownerState, address safe, address signer, uint8 kind) private view {
        OwnerLink storage link = ownerState.owners[signer];
        if (signer == NestedOwnerManagerLib.SENTINEL || link.next == address(0) || link.kind != kind) {
            revert NotAnOwner(safe, signer);
        }
    }

    /// @notice Verify a child Safe's inline signatures or the signed approval backing an empty
    ///         payload.
    /// @dev Binding verification to the child and source-chain domain proves that the child
    ///      authorized this parent hash without calling a destination copy of the Safe.
    function _checkNested(
        SafeAuthorityState storage self,
        address child,
        bytes32 parentHash,
        bytes memory signatures,
        NestedSafeApproval[] memory approvals
    ) private view {
        uint256 chainId = self.sourceChainId;
        bytes32 messageHash = SafeSignaturesUtils.nestedHash(parentHash, child, chainId);
        if (signatures.length != 0) {
            _check(self, child, messageHash, signatures, approvals);
            return;
        }
        SignedSafeTx memory approval = _approval(approvals, child, messageHash);
        _check(
            self,
            child,
            SafeSignaturesUtils.approvalHash(child, parentHash, approval.safeTx, chainId),
            approval.signatures,
            approvals
        );
    }

    /// @notice Find the signed approval for this exact child and message hash, reverting if
    ///         absent.
    /// @dev An empty nested payload is not self-authenticating; the caller must obtain and
    ///      verify the matching child transaction evidence.
    function _approval(NestedSafeApproval[] memory approvals, address child, bytes32 messageHash)
        private
        pure
        returns (SignedSafeTx memory)
    {
        for (uint256 i; i < approvals.length; ++i) {
            if (approvals[i].childSafe == child && approvals[i].messageHash == messageHash) {
                return approvals[i].approval;
            }
        }
        revert MissingNestedSafeApproval(child, messageHash);
    }
}
