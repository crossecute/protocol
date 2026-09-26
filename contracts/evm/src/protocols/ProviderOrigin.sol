// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The origin-chain check every spoke applies to a provider-reported source.
/// @dev A spoke passes `homeRoute()` to `_onInbound` itself, so `_authenticateOrigin` checks
///      only the sender; without this, the hub's address on any other chain the provider
///      reaches would authenticate as the hub. Ids are widened to `uint256`, as in
///      `ProviderChainId`, so one error serves every provider's id width.
library ProviderOrigin {
    error UnexpectedOrigin(uint256 origin);

    function requireHome(uint256 origin, uint256 home) internal pure {
        if (origin != home) revert UnexpectedOrigin(origin);
    }
}
