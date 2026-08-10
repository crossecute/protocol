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
    event Dispatched(bytes32 indexed recipientHash, bytes32 indexed payloadHash);

    error NoDestination();
    error EmptyPayload();
    /// @dev The default `_sendMessage` body. A protocol that forgets to implement it fails
    ///      loudly on the first message rather than silently reporting success for a
    ///      payload that never left.
    error SendNotImplemented();
    /// @dev The default `_quoteMessage` body. The same argument as `SendNotImplemented`,
    ///      in the direction that matters more: a quote that silently returned zero would
    ///      be indistinguishable from a free message, and the first thing anyone would do
    ///      with the answer is send exactly that much.
    error QuoteNotImplemented();

    /// @notice Hand a payload to the gateway for one recipient.
    ///
    /// @dev THE ARGUMENTS ARE ERC-7786's, AND THAT IS THE WHOLE CHANGE. A recipient is a
    ///      binary interoperable address carrying its own chain, so the destination is
    ///      named by the message rather than resolved from a key the caller supplied
    ///      separately. Attributes replace the opaque `providerData` blob for the same
    ///      reason: the standard already has a shape for per-send options.
    function _dispatch(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes
    ) internal returns (bytes32 sendId) {
        if (recipient.length == 0) revert NoDestination();
        if (payload.length == 0) revert EmptyPayload();

        emit Dispatched(keccak256(recipient), keccak256(payload));
        return _sendMessage(recipient, payload, attributes);
    }

    /// @notice Where a provider's excess fee goes back to.
    ///
    /// @dev `msg.sender`, ON BOTH SIDES, AND IT RESOLVES CORRECTLY ON BOTH. A fee is
    ///      overpaid by whoever paid it, so the party who sent the value is the party who
    ///      gets the remainder. That one sentence is the whole rule, and it needs no
    ///      argument threaded through the call stack to state it.
    ///
    ///      On PATH A the sender is the account's owner: `send` is `onlyAccountOwner`, so
    ///      `msg.sender` is the party that signed and funded the message, and the refund
    ///      lands in their wallet.
    ///
    ///      On PATH B the sender is the ACCOUNT: `bootstrap` refuses any caller that is not
    ///      `predictCrossAccount(owner, salt)`, so the refund lands in the account that
    ///      asked for the message. That is the one thing this must not get wrong. A shared
    ///      transceiver refunding to `address(this)` would pool every user's excess into
    ///      infrastructure nobody can withdraw from per-user; refunding to `msg.sender`
    ///      cannot reach the transceiver at all, because the transceiver is never the
    ///      caller of its own `bootstrap`.
    ///
    /// @dev IT IS A FUNCTION RATHER THAN AN INLINE `msg.sender` SO THE TWO SIDES CANNOT
    ///      DRIFT. A binding calls one name from `_sendMessage` and gets the same answer
    ///      wherever it is mixed in, and changing the policy is one edit rather than one
    ///      per protocol multiplied by one per endpoint.
    ///
    /// @dev THE ACCOUNT MUST BE ABLE TO RECEIVE IT. Both halves declare `receive`, which is
    ///      not decoration on the transmitter: a refund is a plain value transfer, and one
    ///      to a contract that cannot accept it reverts the send that earned it.
    function _refundTo() internal view returns (address) {
        return msg.sender;
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
    /// @param attributes Per send, and the standard's own shape for what used to be an
    ///        opaque `providerData` blob. Each is a selector-prefixed value the gateway
    ///        understands, and a gateway MUST refuse one it does not; see
    ///        `supportsAttribute`. They are per send rather than configuration because
    ///        destination gas is a property of the payload: a three-call array needs more
    ///        than a bare `commit`, and a stored default would strand the first message
    ///        that needed more.
    /// @dev IT RETURNS THE GATEWAY'S `sendId`, WHICH IS NOT ALWAYS "DONE". ERC-7786 says a
    ///      zero id means the message is away and a non-zero one means the gateway needs
    ///      further, unstandardised action before it goes. A binding MUST NOT discard a
    ///      non-zero id silently: either it handles the second step or it refuses gateways
    ///      that need one, and it says which in its NatSpec.
    function _sendMessage(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes
    ) internal virtual returns (bytes32 sendId) {
        revert SendNotImplemented();
    }

    /// @notice What `_dispatch` would cost, without dispatching anything.
    ///
    /// @dev THE SAME VALIDATION AS `_dispatch`, MINUS THE EVENT. A quote that succeeded for
    ///      a message the send would refuse tells a caller the operation is ready when it
    ///      is not, which is worse than no quote: the refusal arrives after the signers
    ///      have already approved the payload. So the two entry points agree on what is
    ///      quotable, by sharing the checks rather than by restating them.
    function _quote(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes
    ) internal view returns (uint256 nativeFee) {
        if (recipient.length == 0) revert NoDestination();
        if (payload.length == 0) revert EmptyPayload();

        return _quoteMessage(recipient, payload, attributes);
    }

    /// @notice What putting `payload` on the wire costs, in THIS chain's native currency.
    ///         Implemented per protocol, alongside `_sendMessage`.
    ///
    /// @dev IT IS DECLARED HERE, NEXT TO ITS TWIN, BECAUSE THE TWO ARE ONE OBLIGATION. A
    ///      binding that implements the send and forgets the quote leaves every caller
    ///      guessing at `msg.value`, and the guess is not one anyone can make off-chain:
    ///      the fee is a function of the payload's exact bytes, the destination gas it
    ///      asks for, and the provider's own price feed at that block. Adjacent
    ///      declarations make the omission visible on sight rather than at integration.
    ///
    /// @dev IT IS `view`, WHICH IS THE WHOLE POINT OF IT. The only way a quote is ever used
    ///      is an `eth_call` in the block before the send, so a mutable quote is not a
    ///      quote. Every provider in scope answers this as a view: LayerZero's
    ///      `endpoint.quote`, Hyperlane's `quoteDispatch`, CCIP's `getFee`.
    ///
    /// @dev IT MUST PRICE THE EXACT BYTES THE SEND WOULD CARRY, which is why it takes the
    ///      built `payload` rather than the call array: every provider prices per byte, and
    ///      the callers above hand both functions the output of one builder. An estimate
    ///      of the length would make the answer a number to pad rather than a number to
    ///      send.
    ///
    /// @dev NOTHING CONSULTS IT ON THE SEND PATH, DELIBERATELY. Having `_dispatch` quote
    ///      itself and compare would double the provider round trip on every message and
    ///      turn a price that moved in between into a revert, when the provider's own
    ///      refund already handles it. The quote is advisory, and the excess comes back.
    ///
    /// @dev IT ANSWERS IN NATIVE CURRENCY AND NOTHING ELSE. Where a provider also accepts
    ///      its own token, the binding quotes the native path: signers fund one currency on
    ///      one chain, which is the property the whole protocol is arranged around.
    /// @dev ITS ARGUMENTS ARE `sendMessage`'s, EXACTLY. ERC-7786 defines no quote at all,
    ///      so this is the protocol's own addition, and the one thing it must not do is
    ///      diverge from the call it prices. Same recipient, same payload, same attributes,
    ///      minus the value.
    function _quoteMessage(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes
    ) internal view virtual returns (uint256 nativeFee) {
        revert QuoteNotImplemented();
    }
}
