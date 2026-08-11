// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title OutboundBase
/// @notice The sending half, with no opinion about who is allowed to send.
///
/// @dev SPLIT FROM `TransmitterBase` BECAUSE A TRANSCEIVER NEEDS THE MECHANICS AND MUST NOT
///      HAVE THE OWNER. A transceiver already answers to the crossecute msig, and an account
///      to its user; merging the two would collide on `owner` outright.
///
/// @dev IT DECLARES NO STORAGE, so it mixes into a contract that already has a layout with
///      no slot to collide and no gap to reserve.
///
/// @dev THERE IS NO `_dispatch` WRAPPER. Validation belongs at the entry point where the
///      untrusted argument arrives, and the event it used to emit is now the standard's:
///      a gateway source MUST emit `MessageSent`, which carries strictly more than the two
///      hashes `Dispatched` did. Path B is not a gateway source and emits `BootstrapSent`.
abstract contract OutboundBase {
    /// @dev Raised at the entry point, not in a shared internal. See the note above.
    error NoDestination();
    error EmptyPayload();
    /// @dev The `_sendMessage` default. A protocol that forgets to implement it fails loudly
    ///      on the first message rather than reporting success for one that never left.
    error SendNotImplemented();
    /// @dev The `_quoteMessage` default. Silently returning zero would be indistinguishable
    ///      from a free message, and the first thing anyone would do is send exactly that.
    error QuoteNotImplemented();

    /// @notice Where a provider's excess fee goes back to: whoever paid it.
    ///
    /// @dev `msg.sender` RESOLVES CORRECTLY ON BOTH PATHS with nothing threaded through the
    ///      call stack. On path A `sendMessage` is owner-gated, so it is the wallet that
    ///      signed and funded the message. On path B `bootstrap` refuses any caller that is
    ///      not `predictCrossAccount(owner, salt)`, so it is the ACCOUNT: a shared
    ///      transceiver cannot be its own refund target, because it is never the caller of
    ///      its own `bootstrap`, and refunding to `address(this)` would pool every user's
    ///      excess into infrastructure with no per-user way out.
    ///
    /// @dev A FUNCTION RATHER THAN AN INLINE `msg.sender`, so every binding gets one answer
    ///      and changing the policy is one edit. Both halves of an account declare `receive`
    ///      to accept the transfer; without it the refund reverts the send that earned it.
    function _refundTo() internal view returns (address) {
        return msg.sender;
    }

    /// @notice Put the payload on the wire. Implemented per protocol.
    ///
    /// @dev ONE PRIMITIVE FOR EVERY CHANNEL: a payload to an account, a bootstrap to a spoke
    ///      transceiver, and a receiver report home are all `bytes` to an interoperable
    ///      address. Three signatures would be three places to get authentication or fee
    ///      handling subtly different, and a `bytes32` could express none of them.
    ///
    /// @dev PAYABLE BY THE CALLER, NOT HERE. Every entry point that reaches this is
    ///      `payable`; the binding reads `msg.value` and refunds the excess, since only it
    ///      knows the provider's convention.
    ///
    /// @param attributes Per send, the standard's shape for what was an opaque
    ///        `providerData` blob: selector-prefixed values the gateway understands, and a
    ///        gateway MUST refuse one it does not (see `supportsAttribute`). Per send rather
    ///        than configuration because destination gas is a property of the payload, so a
    ///        stored default would strand the first message that needed more.
    /// @return sendId The gateway's, and NOT always "done". ERC-7786 says a non-zero id means
    ///         further unstandardised action is required, so a binding MUST NOT discard one
    ///         silently: it either handles the second step or refuses such gateways, in
    ///         NatSpec.
    function _sendMessage(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes
    ) internal virtual returns (bytes32 sendId) {
        revert SendNotImplemented();
    }

    /// @notice What `_sendMessage` would cost, in THIS chain's native currency.
    ///
    /// @dev DECLARED NEXT TO ITS TWIN BECAUSE THE TWO ARE ONE OBLIGATION, and ERC-7786
    ///      defines no quote, so this is the protocol's own. A binding that implements the
    ///      send and forgets the quote leaves every caller guessing at a `msg.value` nobody
    ///      can derive off-chain: the fee is a function of the payload's exact bytes, the
    ///      destination gas, and the provider's price feed at that block. Adjacent
    ///      declarations make the omission visible on sight.
    ///
    /// @dev `view`, WHICH IS THE WHOLE POINT. A quote is only ever an `eth_call` in the block
    ///      before the send, so a mutable one is not a quote. Every provider in scope answers
    ///      as a view: LayerZero's `endpoint.quote`, Hyperlane's `quoteDispatch`, CCIP's
    ///      `getFee`.
    ///
    /// @dev IT TAKES THE BUILT `payload`, NOT THE CALL ARRAY, because every provider prices
    ///      per byte and an estimate of the length would be a number to pad rather than a
    ///      number to send. Its arguments are `sendMessage`'s exactly, minus the value: the
    ///      one thing it must not do is price a different message than the one that goes out.
    ///
    /// @dev NOTHING CONSULTS IT ON THE SEND PATH. Quoting inside a send would double the
    ///      provider round trip and turn a price that moved into a revert, when the
    ///      provider's refund already handles it. The quote is advisory.
    ///
    /// @dev NATIVE CURRENCY AND NOTHING ELSE. Where a provider also takes its own token, the
    ///      binding quotes the native path: signers fund one currency on one chain, which is
    ///      the property the whole protocol is arranged around.
    function _quoteMessage(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes
    ) internal view virtual returns (uint256 nativeFee) {
        revert QuoteNotImplemented();
    }
}
