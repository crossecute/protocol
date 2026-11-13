// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {AuthoritySelection, AuthorityUpdate} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {SafeTxEvidence} from "../signed/types/SignedDispatchTypes.sol";
import {AuthorityGraph} from "./AuthorityGraph.sol";
import {AuthorityUpdateEncoding} from "./AuthorityUpdateEncoding.sol";
import {IAuthorityRegistry} from "./IAuthorityRegistry.sol";

/// @notice Non-deployable linked-update state-machine template for #109.
/// @dev Mandatory abstract hooks cover signatures, source calls, genesis, graph and child proofs.
///      Current receivers do not read this state. Concrete integration must freeze the shared
///      context throughout application execution. This is absent from deployment scripts.
abstract contract AuthorityRegistryTemplate is IAuthorityRegistry {
    bytes32 private constant GENESIS_DOMAIN = keccak256("Crossecute.AuthorityGenesis.v1");
    mapping(uint256 => mapping(address => AuthoritySelection)) private _selections;
    mapping(bytes32 => bytes) private _graphs;
    // Exact receipts prevent replay without storing historical authority versions.
    mapping(uint256 => mapping(address => mapping(bytes32 => bool))) private _accepted;
    bool private _submitting;

    error UnregisteredAuthority();
    error AlreadyRegistered();
    error WrongRoot();
    error ZeroCommitment();
    error PreviousUpdateMismatch();
    error PreviousAuthorityMismatch();
    error ReplacementHashMismatch();
    error UpdateAlreadyAccepted();
    error AuthoritySubmissionReentered();
    error GraphNotCached();

    modifier submissionLock() {
        if (_submitting) revert AuthoritySubmissionReentered();
        _submitting = true;
        _;
        _submitting = false;
    }

    /// @inheritdoc IAuthorityRegistry
    function selection(uint256 sourceChainId, address sourceSafe) public view returns (AuthoritySelection memory) {
        return _selections[sourceChainId][sourceSafe];
    }

    /// @inheritdoc IAuthorityRegistry
    function graph(bytes32 authorityHash) external view returns (AuthorityGraph memory) {
        bytes memory encoded = _graphs[authorityHash];
        if (encoded.length == 0) revert GraphNotCached();
        return abi.decode(encoded, (AuthorityGraph));
    }

    /// @inheritdoc IAuthorityRegistry
    function submitAuthority(
        uint256 sourceChainId,
        address sourceSafe,
        SafeTxEvidence calldata evidence,
        AuthorityGraph calldata newGraph,
        bytes calldata childStateProofs
    ) external submissionLock {
        _requireAuthorityContextIdle(sourceChainId, sourceSafe);
        AuthoritySelection memory current = _selections[sourceChainId][sourceSafe];
        if (current.authorityHash == bytes32(0)) revert UnregisteredAuthority();
        if (newGraph.rootSafe != sourceSafe) revert WrongRoot();
        bytes32 updateHash = SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, sourceSafe, sourceChainId);
        if (_accepted[sourceChainId][sourceSafe][updateHash]) revert UpdateAlreadyAccepted();
        if (updateHash == bytes32(0)) revert ZeroCommitment();

        // Decode actual signed calldata; validate recognized guard/call and full portable
        // quorum under current.authorityHash. No default verification implementation exists.
        AuthorityUpdate memory update = _verifySignedUpdate(sourceChainId, sourceSafe, current, evidence);
        if (update.previousUpdateHash != current.updateHead) revert PreviousUpdateMismatch();
        if (update.previousAuthorityHash != current.authorityHash) revert PreviousAuthorityMismatch();
        if (update.newAuthorityHash == bytes32(0)) revert ZeroCommitment();
        if (AuthorityUpdateEncoding.graphHash(sourceChainId, newGraph) != update.newAuthorityHash) {
            revert ReplacementHashMismatch();
        }
        _authenticateGraph(sourceChainId, sourceSafe, newGraph, childStateProofs);

        // Validation precedes writes. Any revert rolls back the lock and receipts too.
        _graphs[update.newAuthorityHash] = abi.encode(newGraph);
        _accepted[sourceChainId][sourceSafe][updateHash] = true;
        _selections[sourceChainId][sourceSafe] = AuthoritySelection(updateHash, update.newAuthorityHash);
        emit AuthoritySelected(sourceChainId, sourceSafe, updateHash, update.newAuthorityHash);
    }

    /// @dev Building block for future authenticated bootstrap; no public initializer here.
    function _initializeAuthority(
        uint256 sourceChainId,
        address sourceSafe,
        AuthorityGraph calldata initialGraph,
        bytes memory creationWitness
    ) internal submissionLock {
        _requireAuthorityContextIdle(sourceChainId, sourceSafe);
        if (_selections[sourceChainId][sourceSafe].authorityHash != bytes32(0)) revert AlreadyRegistered();
        if (sourceSafe == address(0) || initialGraph.rootSafe != sourceSafe) revert WrongRoot();
        _authenticateGenesis(sourceChainId, sourceSafe, initialGraph, creationWitness);
        bytes32 authorityHash = AuthorityUpdateEncoding.graphHash(sourceChainId, initialGraph);
        if (authorityHash == bytes32(0)) revert ZeroCommitment();
        bytes32 head = keccak256(abi.encode(GENESIS_DOMAIN, sourceChainId, sourceSafe, authorityHash));
        if (head == bytes32(0)) revert ZeroCommitment();
        _graphs[authorityHash] = abi.encode(initialGraph);
        _selections[sourceChainId][sourceSafe] = AuthoritySelection(head, authorityHash);
        emit AuthoritySelected(sourceChainId, sourceSafe, head, authorityHash);
    }

    function _verifySignedUpdate(
        uint256 sourceChainId,
        address sourceSafe,
        AuthoritySelection memory current,
        SafeTxEvidence calldata evidence
    ) internal view virtual returns (AuthorityUpdate memory);

    /// @dev Check canonical root closure, 16 owners per Safe, kinds/thresholds, terminating
    ///      cycle enumeration and independent descendant-state witnesses; no extra work caps.
    function _authenticateGraph(
        uint256 sourceChainId,
        address sourceSafe,
        AuthorityGraph calldata authority,
        bytes calldata childStateProofs
    ) internal view virtual;

    /// @dev Prove supported creation/configuration and the complete initial graph independently.
    function _authenticateGenesis(
        uint256 sourceChainId,
        address sourceSafe,
        AuthorityGraph calldata authority,
        bytes memory creationWitness
    ) internal view virtual;

    /// @dev Concrete integration must share application-execution locking across providers.
    function _requireAuthorityContextIdle(uint256 sourceChainId, address sourceSafe) internal view virtual;
}
