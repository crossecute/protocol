// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MessagingContext} from "src/messaging/MessagingContext.sol";

/// @title OutboundBase
/// @notice The sending half, with no opinion about who is allowed to send.
///
/// @dev SPLIT OUT OF `TransmitterBase` BECAUSE THAT CONTRACT DID TWO JOBS. One was the
///      mechanics — build the destination-bound commitment, hand it to the message
///      provider. The other was the per-user entry point that owns those mechanics:
///      `owner`, `onlyOwner`, `submit`. A transceiver needs the first and must not have
///      the second, because it already has an owner (the xsafe msig) and that owner is
///      a different party from the transmitter's. Merging the two contracts collided on
///      `owner` outright; splitting them means a transceiver can be a sender and a
///      receiver at once, which is what it always was in the spec.
///
/// @dev IT DECLARES NO STORAGE, DELIBERATELY. That is what makes it free to mix into a
///      contract that already has a layout — there is no slot to collide, no gap to
///      reserve, and no ordering constraint on the `is` list beyond linearization.
abstract contract OutboundBase is MessagingContext {
    /// @dev One event for the one fact: a commitment left for a destination. Emitting a
    ///      second, prettier one at the entry point would mean two records of a single
    ///      send that an indexer has to reconcile.
    event Dispatched(bytes32 indexed destinationChainKey, bytes32 indexed commitment);

    error ZeroCommitmentOut();
    error NoDestination();
    /// @dev The default `_send` body. A protocol that forgets to implement it fails
    ///      loudly on the first message rather than silently reporting success for a
    ///      payload that never left.
    error SendNotImplemented();

    /// @notice Hand a commitment to the message provider for one destination.
    function _dispatch(bytes32 destinationChainKey, bytes32 commitment) internal {
        if (destinationChainKey == bytes32(0)) revert NoDestination();
        if (commitment == bytes32(0)) revert ZeroCommitmentOut();

        emit Dispatched(destinationChainKey, commitment);
        _send(destinationChainKey, commitment);
    }

    /// @notice Put the commitment on the wire. Implemented per protocol.
    ///
    /// @dev IT TAKES NO CALLS, AND THAT IS THE POINT. A `bytes[]` parameter here would be
    ///      an invitation for some protocol to bridge the payload "for convenience", and
    ///      the entire commit/finalize design exists so that what crosses the bridge is
    ///      something nobody can usefully tamper with. Thirty-two bytes cross; the array
    ///      is supplied on the destination and checked against them there. Removing the
    ///      parameter makes that structural rather than a rule someone has to remember.
    ///
    ///      It receives a chainKey, which is what `counterpartOn` and `receiverSlot`
    ///      already speak, so nothing translates at this boundary — the provider-native id
    ///      is resolved inside the transceiver.
    function _send(bytes32 destinationChainKey, bytes32 commitment) internal virtual {
        revert SendNotImplemented();
    }
}
