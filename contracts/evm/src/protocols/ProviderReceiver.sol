// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";

/// @notice A receiver whose only provider setup is naming the provider's delivery contract as
///         its gateway.
abstract contract ProviderReceiver is ReceiverBase {
    /// @dev `grantRole` is `onlyInitializing`, so this initializer is the only window the
    ///      gateway grant ever gets. It runs before `__ReceiverBase_init`, which executes the
    ///      payload.
    function initialize(address sourceTransmitter_, bytes32 homeOrigin_, Call[] calldata calls)
        external
        override
        initializer
    {
        grantRole(GATEWAY_ROLE, _providerGateway());
        __ReceiverBase_init(sourceTransmitter_, homeOrigin_, calls);
    }

    /// @notice The provider contract that delivers to this receiver.
    function _providerGateway() internal view virtual returns (address);
}
