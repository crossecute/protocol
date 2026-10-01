// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Erc7930} from "src/addressing/Erc7930.sol";
import {Roles} from "src/messaging/Roles.sol";

/// @title OutboundBase
/// @notice The sending half: who this contract's counterpart is on each chain, how to
///         address it, and the two primitives that put a message on the wire.
///
/// @dev Split from `TransmitterBase` because a transceiver needs the mechanics but must not
///      have an account's owner. The setters are `internal` and ungated; each side wraps them
///      in its own authority (`onlyOwner` on a hub, `onlyAccountOwner` on an account), and a
///      spoke exposes none.
///
/// @dev One table serves every sender: an ERC-7930 recipient is the route (chain) joined to
///      the counterpart (address). A hub's counterpart is the far transceiver, a spoke's is
///      the hub, and an account's is its own receiver, stored rather than assumed equal to
///      this address, which is wrong wherever the CREATE2 formula differs from Ethereum's.
///
/// @dev Leads the inheritance list on `TransmitterBase` and `TransceiverBase`, so its fields
///      take the first slots of both layouts (R8.2). `ReceiverBase` does not inherit it.
///
/// @dev Entry points validate their arguments and call `_sendMessage` directly. A gateway
///      source emits `MessageSent`; path B is not one, so `TransceiverBase` emits
///      `BootstrapSent` instead.
abstract contract OutboundBase is Roles {
    /// chainKey => that chain's canonical ERC-7930 chain identifier.
    /// @dev Held by the sender, not the registry: on the execute-on-arrival path nothing else
    ///      binds the destination, so a registry that could misroute could run a payload on
    ///      the wrong chain.
    mapping(bytes32 => bytes) private _routes;

    /// keccak256(identifier) => chainKey, for turning a provider's source id back into a
    /// chain. Written by the same setter as `_routes`, and injective: a collision reverts.
    mapping(bytes32 => bytes32) private _chainKeyOfRoute;

    /// chainKey => this contract's counterpart there, in that chain's own address format.
    /// @dev Raw bytes: the counterpart is not at this address on zkSync or Tron, and a 32-byte
    ///      Solana or Move key cannot be narrowed to 20.
    mapping(bytes32 => bytes) private _counterparts;

    event RouteSet(bytes32 indexed chainKey, bytes route);
    event CounterpartSet(bytes32 indexed chainKey, bytes counterpart);

    error NoDestination();
    error EmptyPayload();
    error ZeroRoute();
    error ZeroCounterpart();
    /// @dev Re-pointing a route would redirect every message to that destination at once.
    error RouteAlreadySet(bytes32 chainKey);
    error NoRouteFor(bytes32 chainKey);
    /// @dev Two chains sharing one identifier would let an inbound message be attributed to
    ///      the wrong source.
    error RouteInUse(bytes32 routeKey);
    error UnknownRoute();
    error NoCounterpartFor(bytes32 chainKey);
    /// @dev For a binding whose provider cannot quote on-chain (P9). Zero would read as free.
    error QuoteNotImplemented();

    /* ================================== routing ================================ */

    /// @notice Record how a destination chain is named. Write-once and ungated: the caller
    ///         applies its own authority.
    ///
    /// @dev The route is the chain's ERC-7930 identifier, so `keccak256(route)` is the
    ///      chainKey and the reverse index is correct by construction. Re-writing the same
    ///      route is a no-op; a different one reverts. There is no repoint path, timelocked or
    ///      otherwise: a wrong route is fixed by redeploying.
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
    ///         own authority and decides whether a second write is allowed.
    /// @dev Rebindable here, unlike a route: a counterpart names one address on an
    ///      already-fixed chain, and on a chain this one cannot recompute it is learned after
    ///      the fact.
    function _setCounterpart(bytes32 chainKey, bytes memory counterpart) internal {
        if (chainKey == bytes32(0)) revert NoDestination();
        if (counterpart.length == 0) revert ZeroCounterpart();

        _counterparts[chainKey] = counterpart;
        emit CounterpartSet(chainKey, counterpart);
    }

    /// @notice The chain a route refers to.
    function chainKeyOfRoute(bytes memory route) public view returns (bytes32 chainKey) {
        chainKey = _chainKeyOfRoute[keccak256(route)];
        if (chainKey == bytes32(0)) revert UnknownRoute();
    }

    /// @notice How a chain is named here. Reverts when unset.
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

    /// @notice How the chain itself is named.
    /// @dev A spoke overrides it: its one destination is fixed at initialization and every
    ///      other key reverts.
    function _routeTo(bytes32 chainKey) internal view virtual returns (bytes memory) {
        return routeFor(chainKey);
    }

    /// @notice Where the counterpart lives.
    /// @dev A hub overrides it to apply the registry's provenance bar, and to answer its own
    ///      address on a `Derived` chain with no counterpart recorded; see `HubTransceiverBase`.
    function _counterpartOn(bytes32 chainKey) internal view virtual returns (bytes memory counterpart) {
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

    /// @notice Revert unless this contract has both a counterpart it trusts and a route on
    ///         `chainKey`.
    /// @dev Called for its reverts; both lookups' values are discarded.
    function _requireRoutable(bytes32 chainKey) internal view {
        _counterpartOn(chainKey);
        _routeTo(chainKey);
    }

    /// @notice The counterpart on `chainKey`, as the ERC-7930 address an ERC-7786 gateway
    ///         takes as a recipient.
    /// @dev Runs both lookups, so building a recipient enforces whatever bar each applies.
    function _recipientOn(bytes32 chainKey) internal view returns (bytes memory) {
        Erc7930.Interop memory io = Erc7930.parseStrict(_routeTo(chainKey));
        return Erc7930.encode(io.chainType, io.chainRef, _counterpartOn(chainKey));
    }

    /* ================================== sending ================================ */

    /// @notice Where a provider's excess fee goes back to: whoever paid it.
    /// @dev On a hub's `bootstrap` that is `msg.sender`, the only account it accepts. Never a
    ///      hub's `address(this)`, which would pool every user's excess. `TransmitterBase` and
    ///      `SpokeTransceiverBase` pay from their own balance and override this to themselves.
    function _refundTo() internal view virtual returns (address) {
        return msg.sender;
    }

    /// @notice Put the payload on the wire. No default, so a binding that omits it does not
    ///         compile.
    ///
    /// @dev One primitive for every channel: a payload to an account, a bootstrap to a spoke,
    ///      and a receiver report home are all `bytes` to an ERC-7930 address.
    ///
    /// @dev Spend `value`, never `msg.value`. On a transmitter `value` is the quote and
    ///      `msg.value` only tops up the balance; the hub takes a bootstrap fee off the top; on
    ///      a nested send `msg.value` is zero.
    ///
    /// @param attributes Selector-prefixed values the gateway understands; it must refuse one
    ///        it does not (see `supportsAttribute`).
    /// @return sendId The gateway's. Under ERC-7786 a non-zero id means further action is
    ///         required, so a binding either handles that step or refuses such gateways.
    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        virtual
        returns (bytes32 sendId);

    /// @notice What `_sendMessage` would cost, in this chain's native currency.
    ///
    /// @dev ERC-7786 defines no quote. It is `view` so it can be `eth_call`ed before the send,
    ///      and takes the built `payload` and the send's arguments, since providers price the
    ///      exact bytes. A provider that also takes its own token is quoted on the native path.
    ///
    /// @dev `_sendMessage` never consults it. A transmitter's entry points call it in the same
    ///      transaction as the send and pay exactly the answer, so it has no time to go stale.
    ///      The spoke's report does the same.
    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        virtual
        returns (uint256 nativeFee);

    /// @notice What sending `payload` to `recipient` would cost, in this chain's native
    ///         currency.
    /// @dev On every sender, not only accounts: a spoke's receiver report is paid from its
    ///      balance, which someone has to price in order to fund. Ungated, since it spends and
    ///      writes nothing; `TransmitterBase` overrides it to apply its send's checks.
    function quoteMessage(bytes calldata recipient, bytes calldata payload, bytes[] calldata attributes)
        external
        view
        virtual
        returns (uint256 nativeFee)
    {
        return _quoteMessage(recipient, payload, attributes);
    }
}
