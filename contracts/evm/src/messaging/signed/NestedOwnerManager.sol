// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnerEntry, OWNER_SAFE} from "src/messaging/signed/ISignedDispatch.sol";

/// @notice An owner's successor in its Safe's list, and whether it is an EOA or a nested Safe.
struct OwnerLink {
    address next;
    uint8 kind;
}

/// @notice The stored owner list, threshold and applied authority counter of one source Safe.
/// @dev `owners` is Safe's own linked list from the sentinel, so reading it back gives
///      `getOwners()` order and membership is one read. A nonzero threshold marks the state
///      initialized. The three counters share a slot.
struct SafeState {
    mapping(address => OwnerLink) owners;
    uint32 ownerCount;
    uint32 threshold;
    uint192 authorityCounter;
}

/// @notice Owner-list operations on a stored `SafeState`, mirroring Safe 1.5.0's `OwnerManager`
///         so the list order stays the source Safe's.
/// @dev The caller authenticates the creation record or the signed mutation before applying it.
library NestedOwnerManager {
    address internal constant SENTINEL = address(1);

    error SafeAlreadyInitialized();
    error SafeNotInitialized();
    error InvalidOwner(address owner);
    error InvalidOwnerKind(address owner);
    error InvalidPredecessor(address prevOwner, address owner);
    error InvalidThreshold(uint256 threshold, uint256 ownerCount);

    function setupOwners(SafeState storage self, address sourceSafe, OwnerEntry[] memory owners, uint256 threshold)
        internal
    {
        if (self.threshold != 0) revert SafeAlreadyInitialized();
        _checkThreshold(threshold, owners.length);

        address next = SENTINEL;
        for (uint256 i = owners.length; i != 0; --i) {
            OwnerEntry memory entry = owners[i - 1];
            _checkNewOwner(self, sourceSafe, entry.owner, entry.kind);
            self.owners[entry.owner] = OwnerLink(next, entry.kind);
            next = entry.owner;
        }
        self.owners[SENTINEL].next = next;
        // forge-lint: disable-next-line(unsafe-typecast) `_checkThreshold` bounds both by uint32
        (self.ownerCount, self.threshold) = (uint32(owners.length), uint32(threshold));
    }

    function addOwnerWithThreshold(
        SafeState storage self,
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

    function removeOwner(SafeState storage self, address prevOwner, address owner, uint256 threshold) internal {
        _requireInitialized(self);
        _checkPredecessor(self, prevOwner, owner);
        uint256 count = uint256(self.ownerCount) - 1;
        _checkThreshold(threshold, count);

        self.owners[prevOwner].next = self.owners[owner].next;
        delete self.owners[owner];
        // forge-lint: disable-next-line(unsafe-typecast) `_checkThreshold` bounds both by uint32
        (self.ownerCount, self.threshold) = (uint32(count), uint32(threshold));
    }

    function swapOwner(
        SafeState storage self,
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

    function changeThreshold(SafeState storage self, uint256 threshold) internal {
        _requireInitialized(self);
        _checkThreshold(threshold, self.ownerCount);
        // forge-lint: disable-next-line(unsafe-typecast) `_checkThreshold` bounds it by uint32
        self.threshold = uint32(threshold);
    }

    /// @notice The owners in list order, which is the source Safe's `getOwners()` order.
    function getOwners(SafeState storage self) internal view returns (OwnerEntry[] memory owners) {
        owners = new OwnerEntry[](self.ownerCount);
        address current = self.owners[SENTINEL].next;
        for (uint256 i; i < owners.length; ++i) {
            OwnerLink storage link = self.owners[current];
            owners[i] = OwnerEntry(current, link.kind);
            current = link.next;
        }
    }

    function _requireInitialized(SafeState storage self) private view {
        if (self.threshold == 0) revert SafeNotInitialized();
    }

    function _checkNewOwner(SafeState storage self, address sourceSafe, address owner, uint8 kind) private view {
        if (owner == address(0) || owner == SENTINEL || owner == sourceSafe || self.owners[owner].next != address(0)) {
            revert InvalidOwner(owner);
        }
        if (kind > OWNER_SAFE) revert InvalidOwnerKind(owner);
    }

    function _checkPredecessor(SafeState storage self, address prevOwner, address owner) private view {
        if (owner == address(0) || owner == SENTINEL || self.owners[prevOwner].next != owner) {
            revert InvalidPredecessor(prevOwner, owner);
        }
    }

    function _checkThreshold(uint256 threshold, uint256 count) private pure {
        if (threshold == 0 || threshold > count || count > type(uint32).max) {
            revert InvalidThreshold(threshold, count);
        }
    }
}
