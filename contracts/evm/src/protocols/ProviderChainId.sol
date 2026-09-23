// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ProviderChainId
/// @notice Maps this protocol's chainKey to a native provider's own id for the same chain
///         (LayerZero's `uint32` eid, CCIP's `uint64` selector, Hyperlane's `uint32` domain).
///
/// @dev Distinct from `ChainRegistry`, which answers a provenance question and has no
///      bearing here. A gateway binding (ERC-7786) never needs this file either: it's told
///      the chain by the recipient (see `OutboundBase`'s note on the route slot). Only the
///      native bindings under `protocols/` use it.
///
/// @dev Hub-side only. A hub has N destinations and needs a table; a spoke has exactly one
///      and takes it as a fixed, write-once initializer argument instead (the same asymmetry
///      `OutboundBase` draws between `_counterpartOn` and a spoke's fixed values), so a spoke
///      binding does not inherit this contract.
///
/// @dev Storage is `uint256` so one mapping backs every provider's narrower id type; each
///      binding's own typed setter (`setEid`, `setSelector`, `setDomain`) narrows on the way
///      in and out.
///
/// @dev Write-once-if-unset, same shape as `OutboundBase._setRoute`: re-declaring the same id
///      is a no-op, a different one reverts, since repointing would silently redirect future
///      sends to a different remote endpoint.
///
/// @dev The reverse index exists because a provider's inbound callback reports the source by
///      its own id, not our chainKey. It's injective by construction — two chainKeys sharing
///      one provider id would let an inbound message from either be attributed to the other —
///      the same property `OutboundBase._chainKeyOfRoute` enforces for routes.
///
/// @dev Zero is the unset sentinel on both sides; no provider in scope ever names a live
///      chain 0 (verified in `docs/provider-research.md` §§4-5 and `docs/todo.md` §2).
///
/// @dev Internal and ungated, like every other setter on `OutboundBase`: the inheriting hub
///      transceiver wraps `_setProviderId` in its own authority.
abstract contract ProviderChainId {
    /// chainKey => the provider's own id for that chain. Zero means unset.
    mapping(bytes32 => uint256) private _providerIdOf;

    /// The inbound direction: a delivery names its origin by the provider's id, and this is
    /// the only way back to a chainKey.
    mapping(uint256 => bytes32) private _chainKeyOfProviderId;

    event ProviderIdSet(bytes32 indexed chainKey, uint256 providerId);

    /// @dev Named distinctly from `OutboundBase.NoDestination`: every hub transceiver
    ///      inherits both and would otherwise collide on the name.
    error NoProviderChainKey();
    error ZeroProviderId();
    error ProviderIdAlreadySet(bytes32 chainKey);
    error ProviderIdInUse(uint256 providerId);
    error NoProviderIdFor(bytes32 chainKey);
    error UnknownProviderId(uint256 providerId);

    /// @notice Write-once, ungated: the caller applies its own authority. See the
    ///         contract-level note for why re-declaring the same id is a no-op while a
    ///         different one reverts.
    function _setProviderId(bytes32 chainKey, uint256 providerId) internal {
        if (chainKey == bytes32(0)) revert NoProviderChainKey();
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

    /// @notice The provider's id for `chainKey`. Reverts when unset.
    function _providerIdFor(bytes32 chainKey) internal view returns (uint256 providerId) {
        providerId = _providerIdOf[chainKey];
        if (providerId == 0) revert NoProviderIdFor(chainKey);
    }

    /// @notice The chainKey a provider id refers to (inbound direction). Reverts when unset.
    function _chainKeyOfProvider(uint256 providerId) internal view returns (bytes32 chainKey) {
        chainKey = _chainKeyOfProviderId[providerId];
        if (chainKey == bytes32(0)) revert UnknownProviderId(providerId);
    }

    /// @notice Whether a provider id is recorded for `chainKey`.
    function hasProviderId(bytes32 chainKey) public view returns (bool) {
        return _providerIdOf[chainKey] != 0;
    }
}
