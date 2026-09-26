// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice What a transmitter reads from its hub. It keeps no table of its own, being per-user
///         and locked after creation, so every send reads the hub's live.
interface IProviderIdTable {
    function providerIdFor(bytes32 chainKey) external view returns (uint256);
}

/// @notice `recipient`'s provider id from `hub`'s table, for the caller to narrow to its width.
function providerIdOf(address hub, bytes memory recipient) view returns (uint256) {
    return IProviderIdTable(hub).providerIdFor(Erc7930.chainKey(recipient));
}

/// @notice The hub side every native binding with a provider chain id shares: the id table,
///         resolving a recipient to its provider id, and mapping a delivery's reported origin
///         back to a route.
abstract contract ProviderHubTransceiver is HubTransceiverBase, ProviderChainId, IProviderIdTable {
    /// @param providerGateway The provider's own delivery contract, granted `GATEWAY_ROLE`
    ///        directly rather than relying on the deployment to list it in `gateways`.
    function __ProviderHub_init(
        address owner_,
        address treasury_,
        address[] calldata gateways,
        address transmitterImplementation_,
        address providerGateway
    ) internal onlyInitializing {
        grantRole(GATEWAY_ROLE, providerGateway);
        __HubTransceiverBase_init(owner_, treasury_, gateways, transmitterImplementation_);
    }

    /// @notice See `IProviderIdTable`. Reverts `NoProviderIdFor` when unset; the typed setters
    ///         are per binding.
    function providerIdFor(bytes32 chainKey) external view returns (uint256) {
        return _providerIdFor(chainKey);
    }

    function _providerIdOf(bytes memory recipient) internal view returns (uint256) {
        return _providerIdFor(Erc7930.chainKey(recipient));
    }

    /// @dev An unmapped `providerId` reverts in `_chainKeyOfProvider`.
    function _onProviderInbound(uint256 providerId, address sender, bytes calldata message) internal {
        _onInbound(routeFor(_chainKeyOfProvider(providerId)), abi.encodePacked(sender), message);
    }
}
