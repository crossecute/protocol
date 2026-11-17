// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {AuthorityUpdate} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "@crossecute/safe-guard/authority/ISourceAuthorityGuard.sol";
import {Bytes} from "src/messaging/signed/Bytes.sol";
import {AuthorityUpdateEncoding} from "./AuthorityUpdateEncoding.sol";
import {ReceiverAuthority} from "./ReceiverAuthority.sol";

/// @notice Classifies the signed source call of an authority update, for the source guard and for
///         receivers.
/// @dev Recognizes exactly the calls the guard accepts: a zero-value DELEGATECALL of the pinned
///      MultiSendCallOnly carrying the one-SafeTx ownership batch, or a zero-value CALL of the
///      guard's `selectAuthority` or `activate`. Anything else reverts.
library AuthorityRecognition {
    uint8 private constant CALL = 0;
    uint8 private constant DELEGATECALL = 1;

    error NotAnAuthorityCall();
    error UnknownGuardSelector(bytes4 selector);

    /// @param guard The source guard's address, which the same bytecode has on every chain.
    /// @param multiSend Safe 1.5.0's MultiSendCallOnly.
    /// @param safe The Safe the call was signed for, whose self-calls the batch carries.
    function recognize(address guard, address multiSend, address safe, SafeTx memory safeTx)
        internal
        pure
        returns (ReceiverAuthority.RecognizedUpdate memory r)
    {
        if (safeTx.value != 0) revert NotAnAuthorityCall();
        if (safeTx.to == multiSend && safeTx.operation == DELEGATECALL) {
            r.kind = ReceiverAuthority.UpdateKind.OwnershipChange;
            (r.update, r.mutations) = AuthorityUpdateEncoding.decodeOwnershipBatch(guard, safe, safeTx.data);
            return r;
        }
        if (safeTx.to != guard || safeTx.operation != CALL || safeTx.data.length < 4) revert NotAnAuthorityCall();
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
