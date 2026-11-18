// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReceiverAuthority} from "./ReceiverAuthority.sol";
import {AuthorityRecognition} from "./AuthorityRecognition.sol";
import {AuthorityGraph} from "./AuthorityGraph.sol";
import {ChildUpdate} from "./ChildUpdate.sol";
import {IReceiverAuthority} from "./IReceiverAuthority.sol";
import {ISignedReceiver} from "src/messaging/inbound/ISignedReceiver.sol";
import {SafeTxEvidence} from "src/messaging/signed/types/SignedDispatchTypes.sol";

/// @notice Shared direct/provider authority submission and exact provider retry authentication.
/// @dev Separate linking keeps the nested ABI codecs outside receiver and verifier size budgets.
library AuthorityTransport {
    /// @notice Decode provider authority data outside the receiver's legacy ABI decoder.
    function receiveAuthority(
        ReceiverAuthority.State storage $,
        uint256 sourceChainId,
        AuthorityRecognition.Context memory context,
        bytes calldata wire
    ) external {
        (, bytes memory submission) = abi.decode(wire, (uint256, bytes));
        bytes32 submissionHash = keccak256(submission);
        if ($.lastSubmissionHash != bytes32(0) && submissionHash == $.lastSubmissionHash) {
            emit ISignedReceiver.DuplicateMessage();
            return;
        }
        _applySubmission($, sourceChainId, context, submission);
    }

    /// @dev Raw ABI arguments keep the nested batch decoder outside each receiver's bytecode.
    function submitBatch(
        ReceiverAuthority.State storage $,
        uint256 sourceChainId,
        AuthorityRecognition.Context memory context,
        bytes calldata args
    ) external {
        bytes[] memory submissions = abi.decode(args, (bytes[]));
        if (submissions.length == 0) revert IReceiverAuthority.EmptyAuthorityBatch();
        for (uint256 i; i < submissions.length; ++i) {
            _applySubmission($, sourceChainId, context, submissions[i]);
        }
    }

    function _applySubmission(
        ReceiverAuthority.State storage $,
        uint256 sourceChainId,
        AuthorityRecognition.Context memory context,
        bytes memory submission
    ) private {
        ReceiverAuthority.SubmissionRequest memory request;
        request.sourceChainId = sourceChainId;
        request.context = context;
        (request.evidence, request.newGraph, request.childUpdates) =
            abi.decode(submission, (SafeTxEvidence, AuthorityGraph, ChildUpdate[]));
        bytes32 updateHash = _submit($, request, keccak256(submission));
        emit IReceiverAuthority.AuthoritySelected(updateHash, $.selection.authorityHash);
    }

    /// @dev Both direct forms decode in this linked library; the receiver keeps its typed ABI.
    function submit(
        ReceiverAuthority.State storage $,
        uint256 sourceChainId,
        AuthorityRecognition.Context memory context,
        bytes calldata args
    ) external {
        _applySubmission($, sourceChainId, context, args);
    }

    function _submit(
        ReceiverAuthority.State storage $,
        ReceiverAuthority.SubmissionRequest memory request,
        bytes32 submissionHash
    ) private returns (bytes32 updateHash) {
        // forge-lint: disable-next-line(calls-loop) each batch entry uses the fixed linked verifier under the receiver lock
        updateHash = ReceiverAuthority.submit($, request);
        $.lastSubmissionHash = submissionHash;
    }
}
