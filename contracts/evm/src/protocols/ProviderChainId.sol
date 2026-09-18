// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ProviderChainId
/// @notice The one thing every NATIVE provider binding needs and none of the core protocol
///         does: a table from this protocol's chainKey to whatever integer that PROVIDER uses
///         to name the same chain.
///
/// @dev NOT `ChainRegistry`, AND NOT A REPLACEMENT FOR ANYTHING THERE. The registry answers
///      "how much can this chain's address be known" once, for every hub. This answers "what
///      does LayerZero/CCIP/Hyperlane call this chain", which is a fact about ONE binding and
///      has no bearing on provenance at all. A gateway binding (ERC-7786) never needs this
///      file, because a gateway is told the chain by the recipient; see `OutboundBase`'s own
///      note on why the route slot holds an ERC-7930 identifier rather than a provider id.
///      This exists only for the native bindings under `protocols/`, where §2 of
///      [`todo.md`](../../../../docs/todo.md) already noted the eid table LayerZero would
///      need; CCIP's `uint64` selector and Hyperlane's `uint32` domain are the same
///      requirement under two more names.
///
/// @dev HUB-SIDE ONLY. A hub has N destinations and needs a table to tell them apart; a spoke
///      has exactly one and is told it at initialization, the same asymmetry `OutboundBase`
///      already draws between `_counterpartOn` (hub: registry lookup) and a spoke's fixed
///      values. A spoke binding does not inherit this contract: it takes its one destination's
///      provider id as a further write-once initializer argument, alongside `homeChainKey_`,
///      `homeChainIdentifier_`, and `homeTransceiver_`, and holds it exactly the way it holds
///      those.
///
/// @dev THREE DIFFERENT WIDTHS, ONE STORAGE SHAPE. LayerZero's eid is a `uint32`, CCIP's
///      selector is a `uint64`, Hyperlane's domain is a `uint32`. `uint256` holds all three
///      without narrowing, so one mapping backs every binding; each binding's own typed
///      setter (`setEid`, `setSelector`, `setDomain`) narrows on the way in and out, and the
///      shared logic below never has to know which provider is calling it.
///
/// @dev WRITE-ONCE-IF-UNSET, THE SAME SHAPE AS `OutboundBase._setRoute`. Re-declaring the
///      SAME id is a no-op, so a replayed configuration transaction is not a failure. A
///      DIFFERENT one reverts: repointing a chain's provider id would resolve every future
///      send to a different remote endpoint than every prior one addressed, which is the same
///      "no recovery path but a redeploy" property a route has, and for the same reason.
///
/// @dev THE REVERSE INDEX IS NOT OPTIONAL. A provider's inbound callback reports the source
///      by ITS id, not by our chainKey, so `_authenticateOrigin` has no other way back to one.
///      Injective by construction: two chainKeys sharing one provider id would let an inbound
///      message from either be attributed to the other, which is a forgery primitive on the
///      authentication path rather than a configuration mistake — exactly the property
///      `OutboundBase._chainKeyOfRoute` enforces for routes, and for the same reason.
///
/// @dev ZERO IS THE SENTINEL FOR "UNSET" ON BOTH SIDES, and it costs nothing: no provider in
///      scope ever names a live chain 0 (LayerZero's eids, CCIP's selectors, and Hyperlane's
///      domains are all nonzero for every real chain, verified against each in
///      `docs/provider-research.md` §§4-5 and `docs/todo.md` §2), so refusing it as an input
///      refuses only a caller's mistake, never a real chain.
///
/// @dev INTERNAL AND UNGATED, LIKE EVERY OTHER SETTER ON `OutboundBase`. This contract has no
///      owner and must not assume one: whoever inherits it (a hub transceiver) wraps
///      `_setProviderId` in its own authority, exactly as `OutboundBase._setRoute` is wrapped
///      in `onlyOwner` there rather than gated here.
abstract contract ProviderChainId {
    /// chainKey => the provider's own id for that chain. Zero means unset.
    mapping(bytes32 => uint256) private _providerIdOf;

    /// The provider's id => chainKey. The inbound direction: a delivery names its origin by
    /// the provider's id, and this is the only way back to a chainKey.
    mapping(uint256 => bytes32) private _chainKeyOfProviderId;

    event ProviderIdSet(bytes32 indexed chainKey, uint256 providerId);

    error NoDestination();
    /// @dev Zero is the unset sentinel on both sides; see the contract-level note.
    error ZeroProviderId();
    /// @dev Re-pointing a chain's provider id would resolve every future send to a different
    ///      remote endpoint than every prior one addressed. A redeploy, not a config edit.
    error ProviderIdAlreadySet(bytes32 chainKey);
    /// @dev Two chains sharing one provider id would let an inbound delivery from either be
    ///      attributed to the other: a forgery primitive, not a config mistake.
    error ProviderIdInUse(uint256 providerId);
    error NoProviderIdFor(bytes32 chainKey);
    error UnknownProviderId(uint256 providerId);

    /// @notice Record the provider's id for a chain. WRITE-ONCE, ungated: the caller applies
    ///         its own authority. See the contract-level note for why re-declaring the SAME
    ///         id is a no-op while a DIFFERENT one reverts.
    function _setProviderId(bytes32 chainKey, uint256 providerId) internal {
        if (chainKey == bytes32(0)) revert NoDestination();
        if (providerId == 0) revert ZeroProviderId();

        uint256 existing = _providerIdOf[chainKey];
        if (existing != 0) {
            if (existing != providerId) revert ProviderIdAlreadySet(chainKey);
            return;
        }

        bytes32 held = _chainKeyOfProviderId[providerId];
        if (held != bytes32(0) && held != chainKey) revert ProviderIdInUse(providerId);

        _providerIdOf[chainKey] = providerId;
        _chainKeyOfProviderId[providerId] = chainKey;
        emit ProviderIdSet(chainKey, providerId);
    }

    /// @notice The provider's id for `chainKey`. Reverts when unset, because an unconfigured
    ///         id and an id of zero are different states and a send that confused them would
    ///         address the provider's own sentinel rather than fail.
    function _providerIdFor(bytes32 chainKey) internal view returns (uint256 providerId) {
        providerId = _providerIdOf[chainKey];
        if (providerId == 0) revert NoProviderIdFor(chainKey);
    }

    /// @notice The chainKey a provider id refers to. The inbound direction, resolved once, at
    ///         the edge. Reverts when unset.
    function _chainKeyOfProvider(uint256 providerId) internal view returns (bytes32 chainKey) {
        chainKey = _chainKeyOfProviderId[providerId];
        if (chainKey == bytes32(0)) revert UnknownProviderId(providerId);
    }

    /// @notice Whether a provider id is recorded for `chainKey`.
    function hasProviderId(bytes32 chainKey) public view returns (bool) {
        return _providerIdOf[chainKey] != 0;
    }
}
