// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice What a transmitter reads from its transceiver. It keeps no table of its own, being
///         per-user and locked after creation, so every send reads the transceiver's live.
interface IProviderIdTable {
    function providerIdFor(bytes32 chainKey) external view returns (uint256);
}

/// @notice `recipient`'s provider id from `transceiver`'s table, for the caller to narrow to its
///         width.
function providerIdOf(address transceiver, bytes memory recipient) view returns (uint256) {
    return IProviderIdTable(transceiver).providerIdFor(Erc7930.chainKey(recipient));
}

/// @title ProviderChainId
/// @notice Maps this protocol's chainKey to a native provider's own id for the same chain
///         (LayerZero's `uint32` eid, CCIP's `uint64` selector, Hyperlane's `uint32` domain).
///
/// @dev Distinct from `ChainRegistry`, which answers a provenance question and has no
///      bearing here. A gateway binding (ERC-7786) never needs this file either: it's told
///      the chain by the recipient (see `OutboundBase`'s note on the route slot). Only the
///      native bindings under `protocols/` use it.
///
/// @dev On every binding transceiver whose provider names chains by its own id. OP Stack's
///      does not: each messenger reaches one chain.
///
/// @dev Storage is `uint256` so one mapping backs every provider's narrower id type; each
///      binding's typed setter (`setEid`, `setSelector`, `setDomain`, `setWormholeChain`)
///      bounds it on the way in, and readers narrow it back.
///
/// @dev Write-once-if-unset, same shape as `OutboundBase._setRoute`: re-declaring the same id
///      is a no-op, a different one reverts, since repointing would silently redirect future
///      sends to a different remote endpoint.
///
/// @dev The reverse index exists because a provider's inbound callback reports the source by
///      its own id, not our chainKey. It is injective: two chainKeys sharing one provider id
///      would let an inbound message from either be attributed to the other. Routes get the
///      same property from `OutboundBase._setRoute`, which requires a route to hash to its key.
///
/// @dev Zero is the unset sentinel on both sides; no provider in scope ever names a live
///      chain 0 (verified in `docs/provider-research.md` §§4-5 and `docs/provider-research.md` §8).
///
/// @dev Internal and ungated, like every other setter on `OutboundBase`: the inheriting
///      transceiver wraps `_setProviderId` in its own authority.
abstract contract ProviderChainId is IProviderIdTable {
    /// chainKey => the provider's own id for that chain. Zero means unset.
    mapping(bytes32 => uint256) private _providerIds;

    /// The inbound direction: a delivery names its origin by the provider's id, and this is
    /// the only way back to a chainKey.
    mapping(uint256 => bytes32) private _chainKeyOfProviderId;

    event ProviderIdSet(bytes32 indexed chainKey, uint256 providerId);

    /// @dev Named distinctly from `OutboundBase.NoDestination`: every binding transceiver
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

        uint256 existing = _providerIds[chainKey];
        if (existing != 0) {
            if (existing != providerId) revert ProviderIdAlreadySet(chainKey);
            return;
        }

        bytes32 held = _chainKeyOfProviderId[providerId];
        if (held != bytes32(0) && held != chainKey) revert ProviderIdInUse(providerId);

        _providerIds[chainKey] = providerId;
        _chainKeyOfProviderId[providerId] = chainKey;
        emit ProviderIdSet(chainKey, providerId);
    }

    /// @notice The provider's id for `chainKey`. Reverts when unset.
    function _providerIdFor(bytes32 chainKey) internal view returns (uint256 providerId) {
        providerId = _providerIds[chainKey];
        if (providerId == 0) revert NoProviderIdFor(chainKey);
    }

    /// @notice The chainKey a provider id refers to (inbound direction). Reverts when unset.
    function _chainKeyOfProvider(uint256 providerId) internal view returns (bytes32 chainKey) {
        chainKey = _chainKeyOfProviderId[providerId];
        if (chainKey == bytes32(0)) revert UnknownProviderId(providerId);
    }

    /// @notice Whether a provider id is recorded for `chainKey`.
    function hasProviderId(bytes32 chainKey) public view returns (bool) {
        return _providerIds[chainKey] != 0;
    }

    /// @notice See `IProviderIdTable`. Reverts `NoProviderIdFor` when unset; the typed setters
    ///         are per binding.
    function providerIdFor(bytes32 chainKey) external view returns (uint256) {
        return _providerIdFor(chainKey);
    }

    /// @notice The provider's id for the chain `recipient` is on.
    function _providerIdOf(bytes memory recipient) internal view returns (uint256) {
        return _providerIdFor(Erc7930.chainKey(recipient));
    }
}
