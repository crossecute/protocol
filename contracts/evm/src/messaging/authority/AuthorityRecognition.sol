// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {AuthorityUpdate} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "@crossecute/safe-guard/authority/ISourceAuthorityGuard.sol";
import {Bytes} from "src/messaging/signed/Bytes.sol";
import {AuthorityUpdateEncoding} from "./AuthorityUpdateEncoding.sol";
import {ReceiverAuthority} from "./ReceiverAuthority.sol";
import {ChildUpdate} from "./ChildUpdate.sol";
import {SafeTxEvidence} from "src/messaging/signed/types/SignedDispatchTypes.sol";

/// @notice Classifies the signed source call of an authority update, for the source guard and for
///         receivers.
/// @dev Recognizes exactly the calls the guard accepts: a zero-value DELEGATECALL of the pinned
///      MultiSendCallOnly carrying the one-SafeTx ownership batch, or a zero-value CALL of the
///      guard's `selectAuthority` or `activate`. Anything else reverts.
library AuthorityRecognition {
    struct Context {
        address guard;
        address multiSend;
        address safe;
    }
    uint8 private constant CALL = 0;
    uint8 private constant DELEGATECALL = 1;

    error NotAnAuthorityCall();
    error UnknownGuardSelector(bytes4 selector);

    function recognizeUpdates(Context memory context, SafeTxEvidence memory evidence, ChildUpdate[] memory children)
        public
        pure
        returns (ReceiverAuthority.Recognized memory recognized)
    {
        recognized.root = recognize(context, evidence.signedSafeTx.safeTx);
        recognized.children = new ReceiverAuthority.RecognizedUpdate[](children.length);
        for (uint256 i; i < children.length; ++i) {
            recognized.children[i] = recognize(
                Context(context.guard, context.multiSend, children[i].sourceSafe),
                children[i].evidence.signedSafeTx.safeTx
            );
        }
    }

    /// @param context The pinned guard and helper, and the Safe the transaction was signed for.
    function recognize(Context memory context, SafeTx memory safeTx)
        public
        pure
        returns (ReceiverAuthority.RecognizedUpdate memory r)
    {
        if (safeTx.value != 0) revert NotAnAuthorityCall();
        if (safeTx.to == context.multiSend && safeTx.operation == DELEGATECALL) {
            r.kind = ReceiverAuthority.UpdateKind.OwnershipChange;
            (r.update, r.mutations) =
                AuthorityUpdateEncoding.decodeOwnershipBatch(context.guard, context.safe, safeTx.data);
            return r;
        }
        if (safeTx.to != context.guard || safeTx.operation != CALL || safeTx.data.length < 4) {
            revert NotAnAuthorityCall();
        }
        // forge-lint: disable-next-line(unsafe-typecast) the first four bytes, after the length check
        bytes4 selector = bytes4(safeTx.data);
        if (selector == ISourceAuthorityGuard.activate.selector) {
            r.kind = ReceiverAuthority.UpdateKind.Activation;
            r.update.newAuthorityHash = abi.decode(Bytes.arguments(safeTx.data, selector), (bytes32));
        } else if (selector == ISourceAuthorityGuard.selectAuthority.selector) {
            r.kind = ReceiverAuthority.UpdateKind.Selection;
            r.update = abi.decode(Bytes.arguments(safeTx.data, selector), (AuthorityUpdate));
        } else {
            revert UnknownGuardSelector(selector);
        }
    }
}
