// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeAuthorityGraph} from "src/messaging/signed/SafeAuthorityGraph.sol";
import {SafeOwnerState, OwnerLink, NestedOwnerManagerLib} from "src/messaging/signed/NestedOwnerManagerLib.sol";
import {OwnerSource, SafeQuorum} from "src/messaging/signed/SafeQuorum.sol";
import {SafeAuthorityRecord, SafeOwner} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
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
/// @dev The signature walk is `SafeQuorum`, reading thresholds and owners from this storage.
library SafeAuthority {
    using NestedOwnerManagerLib for SafeOwnerState;

    /// @dev The source Safes cannot be queried during destination verification, so the destination
    ///      keeps an authenticated local snapshot.
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

    /// @notice The stored authority graph in canonical order.
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
        bytes32 context;
        assembly ("memory-safe") {
            context := self.slot
        }
        SafeQuorum.verify(
            OwnerSource(context, self.sourceChainId, _openStored, _isStoredOwner),
            self.root,
            dataHash,
            signatures,
            approvals
        );
    }

    /// @dev `OwnerSource.open` over storage: the handle is the Safe's `SafeOwnerState` slot.
    function _openStored(bytes32 context, address safe) private view returns (bytes32 owners, uint256 threshold) {
        SafeAuthorityState storage self;
        assembly ("memory-safe") {
            self.slot := context
        }
        SafeOwnerState storage ownerState = self.safes[safe];
        threshold = ownerState.threshold;
        assembly ("memory-safe") {
            owners := ownerState.slot
        }
    }

    /// @dev `OwnerSource.isOwner` over storage. Signature recovery or a claimed child address
    ///      alone does not establish authority, and the linked-list sentinel never counts as an
    ///      owner.
    function _isStoredOwner(bytes32 owners, address signer, uint8 kind) private view returns (bool) {
        SafeOwnerState storage ownerState;
        assembly ("memory-safe") {
            ownerState.slot := owners
        }
        OwnerLink storage link = ownerState.owners[signer];
        return signer != NestedOwnerManagerLib.SENTINEL && link.next != address(0) && link.kind == kind;
    }
}
