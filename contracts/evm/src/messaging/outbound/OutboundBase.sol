// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Erc7930} from "src/addressing/Erc7930.sol";

/// @title OutboundBase
/// @notice The sending half: who this contract's counterpart is on each chain, how to
///         address it, and the two primitives that put a message on the wire.
///
/// @dev SPLIT FROM `TransmitterBase` BECAUSE A TRANSCEIVER NEEDS THE MECHANICS AND MUST NOT
///      HAVE THE OWNER. A transceiver already answers to the crossecute msig, and an account
///      to its user; merging the two would collide on `owner` outright. So the setters below
///      are `internal` and ungated, and each side wraps them in the authority it already
///      has: `onlyAdmin` on a transceiver, `onlyAccountOwner` on an account.
///
/// @dev EVERY SENDER HAS THE SAME TWO QUESTIONS, WHICH IS WHY THIS IS ONE TABLE. To address
///      anything, a sender needs the chain (an ERC-7930 identifier) and the counterpart's
///      address on it, and ERC-7930 is exactly the pair joined. What varies is only what a
///      counterpart IS: a hub's is the transceiver on the far side, a spoke's is the hub,
///      and an ACCOUNT'S IS ITS OWN RECEIVER. Holding one table and letting `_counterpartOn`
///      say which does not just remove duplication: it is what lets an account's peer be a
///      stored fact rather than a guess about its own address, which is wrong on any chain
///      whose CREATE2 formula differs from Ethereum's.
///
/// @dev IT DECLARES STORAGE NOW, AND THAT IS A CONSTRAINT ON ITS CONSUMERS. Both are proxies,
///      so these slots must stay first: `OutboundBase` leads the inheritance list on
///      `TransmitterBase` and `TransceiverBase`, and a base inserted ahead of it would move
///      every field below. `ReceiverBase` does not inherit this at all, because a receiver
///      never sends, so its layout is independent.
///
/// @dev ENTRY POINTS CALL `_sendMessage` DIRECTLY, with nothing in between to drift out of
///      step with either. Validation belongs at the entry point, where the untrusted
///      argument arrives, and the send event belongs to the standard: a gateway source MUST
///      emit `MessageSent`. Path B is not a gateway source, so `TransceiverBase` emits
///      `BootstrapSent` instead.
abstract contract OutboundBase {
    /// chainKey => that chain's canonical ERC-7930 chain identifier.
    ///
    /// @dev IT LIVES ON THE SENDER RATHER THAN IN THE REGISTRY. A registry read would put a
    ///      second shared contract in the path of every send and give a compromised one the
    ///      ability to misroute a payload; on the execute-on-arrival path there is no
    ///      commitment binding the destination, so a wrong identifier means the payload runs
    ///      on the wrong chain.
    mapping(bytes32 => bytes) private _routes;

    /// keccak256(identifier) => chainKey. The inbound direction, which is not optional: a
    /// provider hands over a source id and this contract has to turn it back into a chain.
    ///
    /// @dev MAINTAINED IN THE SAME SETTER, because two setters is how the two directions
    ///      drift apart. It is injective by construction, and a collision reverts.
    mapping(bytes32 => bytes32) private _chainKeyOfRoute;

    /// chainKey => this contract's counterpart there, in that chain's own address format.
    ///
    /// @dev RAW BYTES, NOT `address`. The counterpart is not assumed to be at this contract's
    ///      own address: that holds on most EVM chains and not on zkSync or Tron, whose
    ///      CREATE2 formulas differ, and obviously not on Solana or the Move chains, where a
    ///      32-byte key cannot be narrowed to 20.
    mapping(bytes32 => bytes) private _counterparts;

    event RouteSet(bytes32 indexed chainKey, bytes route);
    event CounterpartSet(bytes32 indexed chainKey, bytes counterpart);

    /// @dev Raised at the entry point, not in a shared internal. See the note above.
    error NoDestination();
    error EmptyPayload();
    error ZeroRoute();
    error ZeroCounterpart();
    /// @dev Re-pointing a route would redirect every message to that destination at once, so
    ///      it is a redeploy rather than a config edit.
    error RouteAlreadySet(bytes32 chainKey);
    error NoRouteFor(bytes32 chainKey);
    /// @dev Two chains sharing one identifier would let an inbound message be attributed to
    ///      the wrong source: a forgery primitive, not a config mistake.
    error RouteInUse(bytes32 routeKey);
    error UnknownRoute();
    error NoCounterpartFor(bytes32 chainKey);
    /// @dev The `_sendMessage` default. A protocol that forgets to implement it fails loudly
    ///      on the first message rather than reporting success for one that never left.
    error SendNotImplemented();
    /// @dev The `_quoteMessage` default. Silently returning zero would be indistinguishable
    ///      from a free message, and the first thing anyone would do is send exactly that.
    error QuoteNotImplemented();

    /* ================================== routing ================================ */

    /// @notice Record how a destination chain is named. WRITE-ONCE, ungated: the caller
    ///         applies its own authority.
    ///
    /// @dev THE ROUTE IS THE CHAIN'S ERC-7930 IDENTIFIER, not a provider's private id for it.
    ///      That is what ERC-7786 removed the need for: a gateway is told the chain by the
    ///      recipient. It also makes the reverse index correct by construction, since
    ///      `keccak256(identifier)` IS the chainKey.
    ///
    /// @dev Re-writing the SAME route is a no-op, so a replayed configuration transaction is
    ///      not a failure. A DIFFERENT one reverts.
    function _setRoute(bytes32 chainKey, bytes memory route) internal {
        if (chainKey == bytes32(0)) revert NoDestination();
        if (route.length == 0) revert ZeroRoute();

        bytes memory existing = _routes[chainKey];
        if (existing.length != 0) {
            if (keccak256(existing) != keccak256(route)) revert RouteAlreadySet(chainKey);
            return;
        }

        bytes32 routeKey = keccak256(route);
        bytes32 held = _chainKeyOfRoute[routeKey];
        if (held != bytes32(0) && held != chainKey) revert RouteInUse(routeKey);

        _routes[chainKey] = route;
        _chainKeyOfRoute[routeKey] = chainKey;
        emit RouteSet(chainKey, route);
    }

    /// @notice Record this contract's counterpart on a chain. Ungated: the caller applies its
    ///         own authority.
    ///
    /// @dev REBINDABLE, UNLIKE A ROUTE, AND THE ASYMMETRY IS DELIBERATE. A route names the
    ///      chain every message to that destination is addressed by, so re-pointing one
    ///      redirects the lot. A counterpart names one address on a chain already fixed, and
    ///      the case that needs correcting is real: on a chain whose addresses this one
    ///      cannot recompute, the value is learned after the fact and a first guess may be
    ///      wrong. Whoever wraps this decides whether to allow the second write.
    function _setCounterpart(bytes32 chainKey, bytes memory counterpart) internal {
        if (chainKey == bytes32(0)) revert NoDestination();
        if (counterpart.length == 0) revert ZeroCounterpart();

        _counterparts[chainKey] = counterpart;
        emit CounterpartSet(chainKey, counterpart);
    }

    /// @notice The chain a route refers to. The inbound direction, resolved once, at the edge.
    function chainKeyOfRoute(bytes memory route) public view returns (bytes32 chainKey) {
        chainKey = _chainKeyOfRoute[keccak256(route)];
        if (chainKey == bytes32(0)) revert UnknownRoute();
    }

    /// @notice How a chain is named here. Reverts when unset, because an unconfigured id and
    ///         an id of zero are different states and a send that confused them would go into
    ///         the void.
    function routeFor(bytes32 chainKey) public view returns (bytes memory route) {
        route = _routes[chainKey];
        if (route.length == 0) revert NoRouteFor(chainKey);
    }

    function hasRoute(bytes32 chainKey) public view returns (bool) {
        return _routes[chainKey].length != 0;
    }

    function hasCounterpart(bytes32 chainKey) public view returns (bool) {
        return _counterparts[chainKey].length != 0;
    }

    /// @notice THE SEAM, one half: how the chain itself is named.
    /// @dev The default answers from the table above. A spoke overrides it, because its one
    ///      destination is fixed at initialization and every other key must revert.
    function _routeTo(bytes32 chainKey) internal view virtual returns (bytes memory) {
        return routeFor(chainKey);
    }

    /// @notice THE SEAM, other half: where the counterpart lives.
    ///
    /// @dev The default answers from the table above, which is what a transmitter and a spoke
    ///      use. A HUB overrides it to read the registry instead, because it holds N claims
    ///      about remote code and each carries a provenance grade that a stored address could
    ///      not express; see `HubTransceiverBase`.
    function _counterpartOn(bytes32 chainKey)
        internal
        view
        virtual
        returns (bytes memory counterpart)
    {
        counterpart = _counterparts[chainKey];
        if (counterpart.length == 0) revert NoCounterpartFor(chainKey);
    }

    /// @notice Where this contract's counterpart lives on `chainKey`.
    function counterpartOn(bytes32 chainKey) public view returns (bytes memory) {
        return _counterpartOn(chainKey);
    }

    /// @notice The chain identifier `chainKey` is configured under.
    function routeTo(bytes32 chainKey) public view returns (bytes memory) {
        return _routeTo(chainKey);
    }

    /// @notice Revert unless this contract can reach `chainKey`: a counterpart it trusts, and
    ///         a route to address it by.
    ///
    /// @dev IT IS CALLED FOR THE REVERT, AND THE NAME SAYS SO. Both lookups throw away their
    ///      values; what matters is that `_counterpartOn` refuses an unknown or under-graded
    ///      counterpart and `_routeTo` refuses an unconfigured destination. A function
    ///      returning values nobody reads invites someone to remove the "unused" call and
    ///      take the check with it.
    function _requireRoutable(bytes32 chainKey) internal view {
        _counterpartOn(chainKey);
        _routeTo(chainKey);
    }

    /// @notice The counterpart on `chainKey`, as a binary interoperable address.
    ///
    /// @dev IT IS THE TWO HALVES OF `_requireRoutable`, JOINED. The route holds the chain and
    ///      `_counterpartOn` holds the address, which is exactly the pair ERC-7930 encodes
    ///      and exactly what an ERC-7786 gateway takes as a recipient. Building it here means
    ///      both lookups happen on the send path, so whatever bar each side applies is
    ///      enforced by construction rather than by a separate call somebody could drop.
    function _recipientOn(bytes32 chainKey) internal view returns (bytes memory) {
        Erc7930.Interop memory io = Erc7930.parseStrict(_routeTo(chainKey));
        return Erc7930.encode(io.chainType, io.chainRef, _counterpartOn(chainKey));
    }

    /* ================================== sending ================================ */

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
    /// @param attributes Selector-prefixed values the gateway understands, and a gateway MUST
    ///        refuse one it does not (see `supportsAttribute`). Per send rather than
    ///        configuration because destination gas is a property of the payload, so a stored
    ///        default would strand the first message that needed more.
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
