// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
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
    error NoRouteFor(bytes32 chainKey);
    /// @dev The route is not the canonical chain identifier that `chainKey` hashes from.
    error RouteKeyMismatch(bytes32 chainKey);
    error UnknownRoute();
    error NoCounterpartFor(bytes32 chainKey);
    /// @dev For a binding whose provider cannot quote on-chain (P9). Zero would read as free.
    error QuoteNotImplemented();

    /* ================================== routing ================================ */

    /// @notice Record how a destination chain is named. Write-once and ungated: the caller
    ///         applies its own authority.
    ///
    /// @dev The route must be the chain's canonical ERC-7930 chain identifier, and
    ///      `keccak256(route)` must be the chainKey: otherwise the reverse index would
    ///      attribute one chain's messages to another, and an account homed there would be
    ///      looked for under the wrong key (#25). A key therefore has exactly one valid route,
    ///      which makes the table write-once and injective without further checks: re-writing
    ///      it is a no-op, and any other route for the key is refused above.
    function _setRoute(bytes32 chainKey, bytes memory route) internal {
        if (chainKey == bytes32(0)) revert NoDestination();
        if (route.length == 0) revert ZeroRoute();
        // `fromIdentifier` parses strictly and reduces to the bare identifier, so both together
        // admit only the canonical bare form, which is how an inbound route arrives.
        if (keccak256(route) != chainKey || ChainKey.fromIdentifier(route) != chainKey) {
            revert RouteKeyMismatch(chainKey);
        }

        if (_routes[chainKey].length != 0) return;

        _routes[chainKey] = route;
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

    /// @notice The chain a route refers to: its hash, provided that route is configured here.
    function chainKeyOfRoute(bytes memory route) public view returns (bytes32 chainKey) {
        chainKey = keccak256(route);
        if (_routes[chainKey].length == 0) revert UnknownRoute();
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
