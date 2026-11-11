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

    /// @notice Validate `records` as canonical and store one state per Safe.
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

    /// @notice The stored graph in canonical order.
    function readRecords(SafeAuthorityState storage self) public view returns (SafeAuthorityRecord[] memory) {
        bytes32 context;
        assembly ("memory-safe") {
            context := self.slot
        }
        return SafeAuthorityGraph.walk(self.root, context, _loadStored);
    }

    function _loadStored(bytes32 context, address safe) private view returns (SafeOwner[] memory, uint256) {
        SafeAuthorityState storage self;
        assembly ("memory-safe") {
            self.slot := context
        }
        SafeOwnerState storage ownerState = self.safes[safe];
        return (ownerState.getOwners(), ownerState.threshold);
    }

    /// @notice Reverts unless `signatures` is a quorum of the root Safe over `dataHash`, with
    ///         every empty nested signature backed by an entry of `approvals`. Unused entries are
    ///         ignored; each `(childSafe, messageHash)` may appear once.
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

    /// @dev The owner behind entry `index`, checked as an owner of the entry's kind. A nested
    ///      Safe's own quorum is verified here, after its membership.
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
            SafeSignaturesUtils.contractSignature(safe, signatures, uint256(s), threshold),
            approvals
        );
    }

    function _requireOwner(SafeOwnerState storage ownerState, address safe, address signer, uint8 kind) private view {
        OwnerLink storage link = ownerState.owners[signer];
        if (signer == NestedOwnerManagerLib.SENTINEL || link.next == address(0) || link.kind != kind) {
            revert NotAnOwner(safe, signer);
        }
    }

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
