// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";

/// @notice What every native binding with a provider chain id shares: the id table, and mapping
///         a delivery's reported origin back to a route, which `_authenticateOrigin` then
///         checks like any other.
abstract contract ProviderTransceiver is TransceiverBase, ProviderChainId {
    /// @notice Name the provider's own delivery contract as a gateway, for a binding whose
    ///         entry point checks `GATEWAY_ROLE`.
    function __ProviderTransceiver_init(address providerGateway) internal onlyInitializing {
        grantRole(GATEWAY_ROLE, providerGateway);
    }

    /// @dev An unmapped `providerId` reverts in `_chainKeyOfProvider`, so a chain this
    ///      transceiver was never configured for cannot deliver at all.
    function _onProviderInbound(uint256 providerId, address sender, bytes calldata message) internal {
        _onInbound(routeFor(_chainKeyOfProvider(providerId)), abi.encodePacked(sender), message);
    }
}
