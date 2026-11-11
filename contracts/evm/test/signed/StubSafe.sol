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

    /// @notice Set the stub's owner array and signature threshold.
    /// @dev Graph and evidence tests need controllable live ownership without deploying a
    ///      complete Safe.
    function setOwners(address[] memory owners_, uint256 threshold_) external {
        _owners = owners_;
        getThreshold = threshold_;
    }

    /// @notice Set the transaction guard address returned by the stub.
    /// @dev Tests can select compatible, incompatible and missing-guard creation paths.
    function setGuard(address guard_) external {
        guard = guard_;
    }

    /// @notice Choose whether the stub's signature check reverts.
    /// @dev Relay tests need to exercise failed live-Safe authorization separately from
    ///      receiver cryptographic verification.
    function setSignaturesFail(bool fail) external {
        signaturesFail = fail;
    }

    /// @notice Return the configured live owner list.
    /// @dev The production graph derivation reads this Safe-compatible query to capture its
    ///      authority snapshot.
    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    /// @notice Return the encoded guard for the expected Safe guard storage query.
    /// @dev Capability discovery should exercise the same storage-read shape as a real Safe.
    function getStorageAt(uint256 offset, uint256 length) external view returns (bytes memory) {
        require(offset == GuardDiscovery.GUARD_STORAGE_SLOT && length == 1);
        return abi.encode(guard);
    }

    /// @notice Revert only when the test has enabled signature failure.
    /// @dev This is a controlled relay stub, not a cryptographic verifier; receiver signature
    ///      tests use the real stored-authority verification code.
    function checkSignatures(address, bytes32, bytes memory) external view {
        if (signaturesFail) revert BadSignatures();
    }

    /// @notice Forward a call and value to the selected target, bubbling any revert.
    /// @dev It models the Safe call after the test guard stages evidence, letting transmitter
    ///      tests observe normal failure rollback.
    function exec(address to, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    /// @notice Accept test ETH into the stub Safe.
    /// @dev Forwarded value and funding scenarios need a payable Safe balance.
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

    /// @notice Enable or disable the stub guard's advertised compatibility.
    /// @dev Mode-discovery tests need to distinguish a present guard from a guard that supports
    ///      the required interface.
    function setAdvertises(bool yes) external {
        advertises = yes;
    }

    /// @notice Report the configured support for Crossecute guard and ERC-165 interfaces.
    /// @dev The transmitter creation probe must see realistic compatibility responses from the
    ///      stub.
    function supportsInterface(bytes4 id) external view returns (bool) {
        return advertises && (id == type(ICrossecuteGuard).interfaceId || id == 0x01ffc9a7);
    }

    /// @notice Store a transaction's signatures and mark its guard record live, omitting
    ///         calldata.
    /// @dev The transmitter must restore exact call data just as it does with the real guard's
    ///      staged record.
    function stage(address safe, SafeTx memory safeTx, bytes memory signatures) external {
        safeTx.data = "";
        _staged[safe] = SignedSafeTx(safeTx, signatures);
        live[safe] = true;
    }

    /// @notice Return a live staged record once, only to its recorded transaction target.
    /// @dev Tests must retain the real guard's target and single-consumption boundaries instead
    ///      of granting arbitrary evidence access.
    function consume(address safe) external returns (SignedSafeTx memory) {
        if (!live[safe]) revert ICrossecuteGuard.NoLiveRecord(safe);
        if (msg.sender != _staged[safe].safeTx.to) revert ICrossecuteGuard.NotSignedTarget(msg.sender);
        live[safe] = false;
        return _staged[safe];
    }

    /// @notice Store a child's signed approval for a selected message hash.
    /// @dev Nested evidence collection tests need controllable source approvals, including
    ///      cases where none exists.
    function cacheApproval(address child, bytes32 messageHash, SignedSafeTx memory a) external {
        _approvals[child][messageHash] = a;
        hasApproval[child][messageHash] = true;
    }

    /// @notice Return the stored child/message approval or revert when absent.
    /// @dev An empty nested signature cannot be collected into a valid wire message without
    ///      matching evidence.
    function getApproval(address child, bytes32 messageHash) external view returns (SignedSafeTx memory) {
        if (!hasApproval[child][messageHash]) revert ICrossecuteGuard.NestedSafeApprovalNotFound(child, messageHash);
        return _approvals[child][messageHash];
    }

    /// @notice Mark a root as published in the stub guard.
    /// @dev Root registration tests can distinguish guard publication from the transmitter's
    ///      later registration state.
    function publish(bytes32 root) external {
        isPublished[root] = true;
    }
}
