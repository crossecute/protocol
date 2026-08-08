// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


/// @title OutboundBase
/// @notice The sending half, with no opinion about who is allowed to send.
///
/// @dev SPLIT OUT OF `TransmitterBase` BECAUSE THAT CONTRACT DOES TWO JOBS. One is the
///      mechanics: hand a payload to the message provider. The other is the per-user
///      entry point that owns those mechanics: `owner`, `onlyOwner`, `send`. A transceiver
///      needs the first and must not have the second, because it already has an owner (the
///      crossecute msig) and that owner is a different party from an account's. Merging the two
///      would collide on `owner` outright.
///
/// @dev IT DECLARES NO STORAGE, DELIBERATELY. That is what makes it free to mix into a
///      contract that already has a layout: there is no slot to collide, no gap to
///      reserve, and no ordering constraint on the `is` list beyond linearization.
abstract contract OutboundBase {
    /// @dev One event for the one fact: a payload left for a destination. It carries the
    ///      HASH rather than the payload: the bytes are already in this transaction's
    ///      calldata, so logging them again would double the cost of every send to make an
    ///      indexer's job marginally easier.
    event Dispatched(bytes32 indexed destinationChainKey, bytes32 indexed payloadHash);

    error NoDestination();
    error EmptyPayload();
    /// @dev The default `_sendMessage` body. A protocol that forgets to implement it fails
    ///      loudly on the first message rather than silently reporting success for a
    ///      payload that never left.
    error SendNotImplemented();

    /// @notice Hand a payload to the message provider for one destination.
    function _dispatch(
        bytes32 destinationChainKey,
        bytes memory payload,
        bytes memory providerData
    ) internal {
        if (destinationChainKey == bytes32(0)) revert NoDestination();
        if (payload.length == 0) revert EmptyPayload();

        emit Dispatched(destinationChainKey, keccak256(payload));
        _sendMessage(destinationChainKey, payload, providerData);
    }

    /// @notice Put the payload on the wire. Implemented per protocol.
    ///
    /// @dev ONE PRIMITIVE FOR EVERY CHANNEL. A payload to an account, a bootstrap message
    ///      to a spoke transceiver, and a receiver report back to the hub are all `bytes`
    ///      to a chainKey. A `bytes32` signature could express none of them (it is why
    ///      the report path could not be built at all), and three signatures would be
    ///      three places for a provider binding to get authentication or fee handling
    ///      subtly different.
    ///
    /// @dev IT CARRIES `bytes`, WHICH IS WHAT EVERY PROVIDER'S TRANSPORT ACTUALLY IS.
    ///      LayerZero takes `bytes message`, Hyperlane `bytes messageBody`, Wormhole
    ///      `bytes payload`, CCIP `bytes data`. Nothing translates at this boundary.
    ///
    ///      It receives a chainKey, which is what `counterpartOn` and `routeTo` already
    ///      speak, so the provider-native id is resolved inside the transceiver rather
    ///      than leaking outward.
    ///
    /// @dev PAYABLE BY THE CALLER, NOT HERE. Every entry point that reaches this is
    ///      `payable` and the provider adapter reads `msg.value` to pay the fee; refunding
    ///      the excess is the adapter's job, since only it knows the provider's refund
    ///      convention.
    ///
    /// @param providerData Opaque, and per send. LayerZero wants executor options and a
    ///        refund address, Wormhole a consistency level, CCIP an `extraArgs` blob:
    ///        no argument list fits them all, and a fixed one would have to be widened
    ///        again for the next provider. It is the same reasoning that keeps `route`
    ///        opaque in the registry: this layer has no business knowing what an executor
    ///        option is.
    ///
    ///        It is PER SEND rather than configuration because destination gas is a
    ///        property of the payload: a three-call array needs more than a bare
    ///        `commit`, and a stored default would strand the first message that needed
    ///        more. Empty means "the adapter's default", which is what the convenience
    ///        overloads pass.
    function _sendMessage(
        bytes32 destinationChainKey,
        bytes memory payload,
        bytes memory providerData
    ) internal virtual {
        revert SendNotImplemented();
    }
}
