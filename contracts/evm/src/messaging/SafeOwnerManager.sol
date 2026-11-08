// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @notice Receiver-side owner list and threshold for one source Safe.
struct SafeState {
    address sourceSafe;
    mapping(address => address) nextOwner;
    uint256 ownerCount;
    uint256 threshold;
}

/// @notice Selectors and arguments of the supported Safe owner mutations.
interface ISafeOwnerMutation {
    function addOwnerWithThreshold(address owner, uint256 threshold) external;
    function removeOwner(address prevOwner, address owner, uint256 threshold) external;
    function swapOwner(address prevOwner, address oldOwner, address newOwner) external;
    function changeThreshold(uint256 threshold) external;
}

/// @notice Proposed owner-list operations for the receiver's stored Safe records.
/// @dev The caller authenticates the genesis record or the exact signed mutation before applying it.
library SafeOwnerManager {
    address internal constant SENTINEL = address(1);

    error InvalidSafe(address sourceSafe);
    error SafeAlreadyInitialized();
    error SafeNotInitialized();
    error InvalidOwner(address owner);
    error InvalidPredecessor(address prevOwner, address owner);
    error InvalidThreshold(uint256 threshold, uint256 ownerCount);

    function setupOwners(SafeState storage self, address sourceSafe, address[] memory owners, uint256 threshold)
        internal
    {
        if (self.sourceSafe != address(0)) revert SafeAlreadyInitialized();
        if (sourceSafe == address(0) || sourceSafe == SENTINEL) revert InvalidSafe(sourceSafe);
        _checkThreshold(threshold, owners.length);

        self.sourceSafe = sourceSafe;
        address next = SENTINEL;
        for (uint256 i = owners.length; i != 0; --i) {
            address owner = owners[i - 1];
            _checkNewOwner(self, owner);
            self.nextOwner[owner] = next;
            next = owner;
        }
        self.nextOwner[SENTINEL] = next;
        self.ownerCount = owners.length;
        self.threshold = threshold;
    }

    function addOwnerWithThreshold(SafeState storage self, address owner, uint256 threshold) internal {
        _requireInitialized(self);
        _checkNewOwner(self, owner);
        uint256 count = self.ownerCount + 1;
        _checkThreshold(threshold, count);

        self.nextOwner[owner] = self.nextOwner[SENTINEL];
        self.nextOwner[SENTINEL] = owner;
        self.ownerCount = count;
        self.threshold = threshold;
    }

    function removeOwner(SafeState storage self, address prevOwner, address owner, uint256 threshold) internal {
        _requireInitialized(self);
        _checkPredecessor(self, prevOwner, owner);
        uint256 count = self.ownerCount - 1;
        _checkThreshold(threshold, count);

        self.nextOwner[prevOwner] = self.nextOwner[owner];
        delete self.nextOwner[owner];
        self.ownerCount = count;
        self.threshold = threshold;
    }

    function swapOwner(SafeState storage self, address prevOwner, address oldOwner, address newOwner) internal {
        _requireInitialized(self);
        _checkNewOwner(self, newOwner);
        _checkPredecessor(self, prevOwner, oldOwner);

        self.nextOwner[newOwner] = self.nextOwner[oldOwner];
        self.nextOwner[prevOwner] = newOwner;
        delete self.nextOwner[oldOwner];
    }

    function changeThreshold(SafeState storage self, uint256 threshold) internal {
        _requireInitialized(self);
        _checkThreshold(threshold, self.ownerCount);
        self.threshold = threshold;
    }

    function getOwners(SafeState storage self) internal view returns (address[] memory owners) {
        owners = new address[](self.ownerCount);
        address current = self.nextOwner[SENTINEL];
        for (uint256 i; i < owners.length; ++i) {
            owners[i] = current;
            current = self.nextOwner[current];
        }
    }

    function _requireInitialized(SafeState storage self) private view {
        if (self.sourceSafe == address(0)) revert SafeNotInitialized();
    }

    function _checkNewOwner(SafeState storage self, address owner) private view {
        if (owner == address(0) || owner == SENTINEL || owner == self.sourceSafe || self.nextOwner[owner] != address(0))
        {
            revert InvalidOwner(owner);
        }
    }

    function _checkPredecessor(SafeState storage self, address prevOwner, address owner) private view {
        if (owner == address(0) || owner == SENTINEL || self.nextOwner[prevOwner] != owner) {
            revert InvalidPredecessor(prevOwner, owner);
        }
    }

    function _checkThreshold(uint256 threshold, uint256 count) private pure {
        if (threshold == 0 || threshold > count) revert InvalidThreshold(threshold, count);
    }
}
