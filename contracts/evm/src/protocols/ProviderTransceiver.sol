// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";
import {Call} from "src/messaging/Call.sol";

/// @notice What every native binding with a provider chain id shares: the id table, and mapping
///         a delivery's reported origin back to a route, which `_authenticateOrigin` then
///         checks like any other.
abstract contract ProviderTransceiver is TransceiverBase, ProviderChainId {
    /// @notice Name the provider's own delivery contract as a gateway, for a binding whose
    ///         entry point checks `GATEWAY_ROLE`.
    function __ProviderTransceiver_init(address providerGateway) internal onlyInitializing {
        grantRole(GATEWAY_ROLE, providerGateway);
    }

    /// @notice Name the provider's id for the governor's home, so the bootstrap that creates
    ///         this transceiver's owner can be accepted. Zero leaves it to the owner, which only
    ///         the governor's home can do.
    function _initGovernorHomeId(bytes memory governorHome, uint256 providerId) internal onlyInitializing {
        if (providerId != 0) _setProviderId(keccak256(governorHome), providerId);
    }

    /// @dev An unmapped `providerId` reverts in `_chainKeyOfProvider`, so a chain this
    ///      transceiver was never configured for cannot deliver at all.
    function _onProviderInbound(uint256 providerId, address sender, bytes calldata message) internal {
        _onInbound(routeFor(_chainKeyOfProvider(providerId)), abi.encodePacked(sender), message);
    }

    /// @inheritdoc TransceiverBase
    /// @dev A receiver names its home by the provider's id for it, from the table that admitted
    ///      the bootstrap, since that is how its deliveries report their origin.
    function _accountInitializer(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls
    ) internal view virtual override returns (bytes memory) {
        if (homeChainKey == localChainKey) {
            return super._accountInitializer(owner, salt, homeChainKey, sourceTransmitter, calls);
        }
        return
            abi.encodeCall(IReceiverInit.initialize, (sourceTransmitter, bytes32(_providerIdFor(homeChainKey)), calls));
    }
}
