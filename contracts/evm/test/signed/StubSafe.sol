// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICrossecuteGuard, SafeTx, SignedSafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {GuardDiscovery} from "@crossecute/safe-guard/GuardDiscovery.sol";

/// @notice The Safe 1.5.0 surface the signed contracts read: owners, threshold, the guard slot,
///         and a signature check the test sets to pass or fail. It also forwards calls, standing
///         in for `execTransaction` after its guard staged a record.
contract StubSafe {
    address[] internal _owners;
    uint256 public getThreshold;
    address public guard;
    bool public signaturesFail;

    error BadSignatures();

    function setOwners(address[] memory owners_, uint256 threshold_) external {
        _owners = owners_;
        getThreshold = threshold_;
    }

    function setGuard(address guard_) external {
        guard = guard_;
    }

    function setSignaturesFail(bool fail) external {
        signaturesFail = fail;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function getStorageAt(uint256 offset, uint256 length) external view returns (bytes memory) {
        require(offset == GuardDiscovery.GUARD_STORAGE_SLOT && length == 1);
        return abi.encode(guard);
    }

    function checkSignatures(address, bytes32, bytes memory) external view {
        if (signaturesFail) revert BadSignatures();
    }

    function exec(address to, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    receive() external payable {}
}

/// @notice The `ICrossecuteGuard` surface a transmitter uses, with records the test stages.
contract StubGuard {
    mapping(address safe => SignedSafeTx) internal _staged;
    mapping(address safe => bool) public live;
    mapping(address child => mapping(bytes32 messageHash => SignedSafeTx)) internal _approvals;
    mapping(address child => mapping(bytes32 messageHash => bool)) public hasApproval;
    mapping(bytes32 root => bool) public isPublished;
    bool public advertises = true;

    function setAdvertises(bool yes) external {
        advertises = yes;
    }

    function supportsInterface(bytes4 id) external view returns (bool) {
        return advertises && (id == type(ICrossecuteGuard).interfaceId || id == 0x01ffc9a7);
    }

    /// @dev `data` is cleared, as the real guard returns it.
    function stage(address safe, SafeTx memory safeTx, bytes memory signatures) external {
        safeTx.data = "";
        _staged[safe] = SignedSafeTx(safeTx, signatures);
        live[safe] = true;
    }

    function consume(address safe) external returns (SignedSafeTx memory) {
        if (!live[safe]) revert ICrossecuteGuard.NoLiveRecord(safe);
        if (msg.sender != _staged[safe].safeTx.to) revert ICrossecuteGuard.NotSignedTarget(msg.sender);
        live[safe] = false;
        return _staged[safe];
    }

    function cacheApproval(address child, bytes32 messageHash, SignedSafeTx memory a) external {
        _approvals[child][messageHash] = a;
        hasApproval[child][messageHash] = true;
    }

    function getApproval(address child, bytes32 messageHash) external view returns (SignedSafeTx memory) {
        if (!hasApproval[child][messageHash]) revert ICrossecuteGuard.NestedSafeApprovalNotFound(child, messageHash);
        return _approvals[child][messageHash];
    }

    function publish(bytes32 root) external {
        isPublished[root] = true;
    }
}
