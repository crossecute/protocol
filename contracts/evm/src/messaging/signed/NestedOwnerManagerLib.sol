// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeOwner, OWNER_SAFE} from "src/messaging/signed/types/SafeAuthorityTypes.sol";

/// @notice An owner's successor in its Safe's list, and whether it is an EOA or a nested Safe.
struct OwnerLink {
    address next;
    uint8 kind;
}

/// @notice The stored owner list, threshold and applied authority counter of one source Safe.
/// @dev `owners` is Safe's own linked list from the sentinel, so reading it back gives
///      `getOwners()` order and membership is one read. A nonzero threshold marks the state
///      initialized. The three counters share a slot.
struct SafeOwnerState {
    mapping(address => OwnerLink) owners;
    uint32 ownerCount;
    uint32 threshold;
    uint192 authorityCounter;
}

/// @notice Owner-list operations on a stored `SafeOwnerState`, mirroring Safe 1.5.0's `OwnerManager`
///         so the list order stays the source Safe's.
/// @dev The caller authenticates the creation record or the signed mutation before applying it.
library NestedOwnerManagerLib {
    address internal constant SENTINEL = address(1);

    error SafeOwnerStateAlreadyInitialized();
    error SafeOwnerStateNotInitialized();
    error InvalidOwner(address owner);
    error InvalidOwnerKind(address owner);
    error InvalidPredecessor(address prevOwner, address owner);
    error InvalidThreshold(uint256 threshold, uint256 ownerCount);

    /// @notice Initialize a Safe's stored owner list and threshold once, preserving the
    ///         supplied owner order.
    /// @dev Receivers need a local ownership snapshot that mirrors the source Safe without
    ///      calling it across chains. The caller must authenticate the record before storing
    ///      it.
    function setupOwners(SafeOwnerState storage self, address sourceSafe, SafeOwner[] memory owners, uint256 threshold)
        internal
    {
        if (self.threshold != 0) revert SafeOwnerStateAlreadyInitialized();
        _checkThreshold(threshold, owners.length);

        address next = SENTINEL;
        for (uint256 i = owners.length; i != 0; --i) {
            SafeOwner memory safeOwner = owners[i - 1];
            _checkNewOwner(self, sourceSafe, safeOwner.owner, safeOwner.kind);
            self.owners[safeOwner.owner] = OwnerLink(next, safeOwner.kind);
            next = safeOwner.owner;
        }
        self.owners[SENTINEL].next = next;
        // forge-lint: disable-next-line(unsafe-typecast) `_checkThreshold` bounds both by uint32
        (self.ownerCount, self.threshold) = (uint32(owners.length), uint32(threshold));
    }

    /// @notice Insert a new owner at the front of the list and set the resulting threshold.
    /// @dev Mirroring Safe's insertion rule keeps replicated owner order consistent when an
    ///      authenticated authority update is applied.
    function addOwnerWithThreshold(
        SafeOwnerState storage self,
        address sourceSafe,
        address owner,
        uint8 kind,
        uint256 threshold
    ) internal {
        _requireInitialized(self);
        _checkNewOwner(self, sourceSafe, owner, kind);
        uint256 count = uint256(self.ownerCount) + 1;
        _checkThreshold(threshold, count);

        self.owners[owner] = OwnerLink(self.owners[SENTINEL].next, kind);
        self.owners[SENTINEL].next = owner;
        // forge-lint: disable-next-line(unsafe-typecast) `_checkThreshold` bounds both by uint32
        (self.ownerCount, self.threshold) = (uint32(count), uint32(threshold));
    }

    /// @notice Unlink an owner and set a threshold valid for the remaining owners.
    /// @dev Checking the supplied predecessor prevents removing the wrong list entry; threshold
    ///      validation prevents leaving an unusable owner configuration.
    function removeOwner(SafeOwnerState storage self, address prevOwner, address owner, uint256 threshold) internal {
        _requireInitialized(self);
        _checkPredecessor(self, prevOwner, owner);
        uint256 count = uint256(self.ownerCount) - 1;
        _checkThreshold(threshold, count);

        self.owners[prevOwner].next = self.owners[owner].next;
        delete self.owners[owner];
        // forge-lint: disable-next-line(unsafe-typecast) `_checkThreshold` bounds both by uint32
        (self.ownerCount, self.threshold) = (uint32(count), uint32(threshold));
    }

    /// @notice Replace an owner in its existing list position with a new owner and kind.
    /// @dev Preserving list order mirrors Safe's replacement operation without changing the
    ///      owner count or threshold.
    function swapOwner(
        SafeOwnerState storage self,
        address sourceSafe,
        address prevOwner,
        address oldOwner,
        address newOwner,
        uint8 newKind
    ) internal {
        _requireInitialized(self);
        _checkNewOwner(self, sourceSafe, newOwner, newKind);
        _checkPredecessor(self, prevOwner, oldOwner);

        self.owners[newOwner] = OwnerLink(self.owners[oldOwner].next, newKind);
        self.owners[prevOwner].next = newOwner;
        delete self.owners[oldOwner];
    }

    /// @notice Set a nonzero threshold no greater than the current owner count.
    /// @dev Stored verification must use a satisfiable quorum and fit the packed threshold
    ///      field.
    function changeThreshold(SafeOwnerState storage self, uint256 threshold) internal {
        _requireInitialized(self);
        _checkThreshold(threshold, self.ownerCount);
        // forge-lint: disable-next-line(unsafe-typecast) `_checkThreshold` bounds it by uint32
        self.threshold = uint32(threshold);
    }

    /// @notice Return each stored owner and kind in source Safe list order.
    /// @dev Canonical graph reconstruction needs the original order, not an address-sorted
    ///      approximation.
    function getOwners(SafeOwnerState storage self) internal view returns (SafeOwner[] memory owners) {
        owners = new SafeOwner[](self.ownerCount);
        address current = self.owners[SENTINEL].next;
        for (uint256 i; i < owners.length; ++i) {
            OwnerLink storage link = self.owners[current];
            owners[i] = SafeOwner(current, link.kind);
            current = link.next;
        }
    }

    /// @notice Reject owner-list changes before a nonzero threshold has been stored.
    /// @dev A mutation must update an existing Safe state rather than accidentally creating a
    ///      partial owner list.
    function _requireInitialized(SafeOwnerState storage self) private view {
        if (self.threshold == 0) revert SafeOwnerStateNotInitialized();
    }

    /// @notice Reject reserved, self, duplicate or unsupported owner entries.
    /// @dev Keeping those entries out protects list integrity and limits verification to the
    ///      supported EOA and nested-Safe owner kinds.
    function _checkNewOwner(SafeOwnerState storage self, address sourceSafe, address owner, uint8 kind) private view {
        if (owner == address(0) || owner == SENTINEL || owner == sourceSafe || self.owners[owner].next != address(0)) {
            revert InvalidOwner(owner);
        }
        if (kind > OWNER_SAFE) revert InvalidOwnerKind(owner);
    }

    /// @notice Check that `prevOwner` points directly to the nonreserved owner being changed.
    /// @dev Linked-list removal and replacement depend on the exact predecessor; accepting
    ///      another link would corrupt the list.
    function _checkPredecessor(SafeOwnerState storage self, address prevOwner, address owner) private view {
        if (owner == address(0) || owner == SENTINEL || self.owners[prevOwner].next != owner) {
            revert InvalidPredecessor(prevOwner, owner);
        }
    }

    /// @notice Check that the quorum is nonzero, achievable and representable in the packed
    ///         state.
    /// @dev Owner count and threshold share 32-bit fields, so validation must happen before
    ///      either value is narrowed.
    function _checkThreshold(uint256 threshold, uint256 count) private pure {
        if (threshold == 0 || threshold > count || count > type(uint32).max) {
            revert InvalidThreshold(threshold, count);
        }
    }
}
