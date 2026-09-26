// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice The hub side every native binding with a provider chain id shares: the id table,
///         resolving a recipient to its provider id, and mapping a delivery's reported origin
///         back to a route.
abstract contract ProviderHubTransceiver is HubTransceiverBase, ProviderChainId {
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

    function _providerIdOf(bytes memory recipient) internal view returns (uint256) {
        return _providerIdFor(Erc7930.chainKey(recipient));
    }

    /// @dev An unmapped `providerId` reverts in `_chainKeyOfProvider`.
    function _onProviderInbound(uint256 providerId, address sender, bytes calldata message) internal {
        _onInbound(routeFor(_chainKeyOfProvider(providerId)), abi.encodePacked(sender), message);
    }
}
