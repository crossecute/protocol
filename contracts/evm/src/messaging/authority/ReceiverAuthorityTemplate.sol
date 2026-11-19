// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AuthoritySelection} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {SafeAuthorityRecord} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {SafeTxEvidence} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {AuthorityGraph} from "./AuthorityGraph.sol";
import {ChildUpdate} from "./ChildUpdate.sol";
import {IReceiverAuthority} from "./IReceiverAuthority.sol";
import {AuthorityRecognition} from "./AuthorityRecognition.sol";
import {AuthorityTransport} from "./AuthorityTransport.sol";
import {ReceiverAuthority} from "./ReceiverAuthority.sol";

/// @notice Shared authority entry points over the linked `ReceiverAuthority` library.
/// @dev Source identity, recognition pins and context locking are abstract hooks.
/// @dev State is ERC-7201 namespaced so a receiver can add it without extending its base's
///      sequential layout (R8.2).
abstract contract ReceiverAuthorityTemplate is IReceiverAuthority {
    using ReceiverAuthority for ReceiverAuthority.State;

    // keccak256(abi.encode(uint256(keccak256("crossecute.storage.ReceiverAuthority")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RECEIVER_AUTHORITY_STORAGE =
        0x6d0209d4e0e1a183e61dfc4b31b842ce90252036bca12cdc82cfe5ab3e835800;

    struct AuthorityStorage {
        ReceiverAuthority.State authority;
        bool submitting;
    }

    error AuthoritySubmissionReentered();

    function _authorityStorage() private pure returns (AuthorityStorage storage $) {
        assembly ("memory-safe") {
            $.slot := RECEIVER_AUTHORITY_STORAGE
        }
    }

    function _authority() internal view returns (ReceiverAuthority.State storage $) {
        return _authorityStorage().authority;
    }

    /// @inheritdoc IReceiverAuthority
    function selection() public view returns (AuthoritySelection memory) {
        return _authority().selection;
    }

    /// @inheritdoc IReceiverAuthority
    function graph(bytes32 authorityHash) public view returns (AuthorityGraph memory) {
        return _authority().graph(authorityHash);
    }

    /// @inheritdoc IReceiverAuthority
    function record(bytes32 recordHash) public view returns (SafeAuthorityRecord memory) {
        return _authority().record(recordHash);
    }

    /// @notice Store the head and selected graph a bootstrap carried, once.
    function _seedAuthority(bytes32 updateHead, AuthorityGraph memory initial) internal {
        (uint256 sourceChainId, address sourceSafe) = _authoritySource();
        bytes32 authorityHash = _authority().seed(sourceChainId, sourceSafe, updateHead, initial);
        emit AuthoritySelected(updateHead, authorityHash);
    }

    /// @inheritdoc IReceiverAuthority
    function submitAuthority(
        SafeTxEvidence calldata evidence,
        AuthorityGraph calldata newGraph,
        ChildUpdate[] calldata childUpdates
    ) external virtual {
        (evidence, newGraph, childUpdates);
        AuthorityStorage storage $ = _authorityStorage();
        if ($.submitting) revert AuthoritySubmissionReentered();
        $.submitting = true;
        _applyAuthority(msg.data[4:]);
        $.submitting = false;
    }

    /// @inheritdoc IReceiverAuthority
    function submitAuthorityBatch(bytes[] calldata submissions) external virtual {
        submissions;
        AuthorityStorage storage $ = _authorityStorage();
        if ($.submitting) revert AuthoritySubmissionReentered();
        $.submitting = true;
        _applyAuthorityBatch(msg.data[4:]);
        $.submitting = false;
    }

    function _authorityContext() private view returns (uint256 chainId, AuthorityRecognition.Context memory context) {
        (chainId, context.safe) = _authoritySource();
        (context.guard, context.multiSend) = _recognitionPins();
    }

    function _applyAuthorityBatch(bytes calldata args) internal {
        _requireAuthorityContextIdle();
        (uint256 chainId, AuthorityRecognition.Context memory context) = _authorityContext();
        AuthorityTransport.submitBatch(_authority(), chainId, context, args);
    }

    function _applyAuthority(bytes calldata args) internal {
        _requireAuthorityContextIdle();
        (uint256 chainId, AuthorityRecognition.Context memory context) = _authorityContext();
        AuthorityTransport.submit(_authority(), chainId, context, args);
    }

    /// @dev Immutable source guard and MultiSendCallOnly addresses for source-call recognition.
    function _recognitionPins() internal view virtual returns (address guard, address multiSend);

    /// @dev The receiver's source chain and owner Safe.
    function _authoritySource() internal view virtual returns (uint256 sourceChainId, address sourceSafe);

    /// @dev Concrete integration must share application-execution locking across providers.
    function _requireAuthorityContextIdle() internal view virtual;
}
