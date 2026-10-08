// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";
import {providerIdOf} from "src/protocols/ProviderChainId.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Per-user transmitter, created by `TransceiverBase.createTransmitter`.
/// @dev Sender-only: no `executeVAAv1`, so R3.1 is answered by absence rather than a guard.
///      It is the Wormhole emitter its receivers authenticate.
contract WormholeTransmitter is OwnableTransmitter {
    /// @notice Core bridge and Executor on this chain. Set on the implementation; safe because
    ///         the implementation address lives in the proxy's ERC-1967 slot, not its initcode,
    ///         so these never move a derived address.
    address public immutable coreBridge;
    address public immutable executor;

    constructor(address coreBridge_, address executor_) {
        if (coreBridge_ == address(0)) revert ProviderAddress.ZeroEndpoint();
        if (executor_ == address(0)) revert ProviderAddress.ZeroEndpoint();
        coreBridge = coreBridge_;
        executor = executor_;
    }

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        return WormholeMessage.send(
            _route(recipient), recipient, payload, attributes, value, _refundTo(), _defaultGas(payload)
        );
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        return WormholeMessage.quote(_route(recipient), attributes, _defaultGas(payload));
    }

    bytes4 public constant WORMHOLE_EXECUTION_ATTRIBUTE = WormholeMessage.EXECUTION_ATTRIBUTE;

    function supportsAttribute(bytes4 selector) external pure override returns (bool) {
        return selector == WORMHOLE_EXECUTION_ATTRIBUTE;
    }

    function _route(bytes memory recipient) internal view returns (WormholeMessage.Route memory) {
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint16 setter
        uint16 targetChain = uint16(providerIdOf(transceiver, recipient));
        return WormholeMessage.Route(coreBridge, executor, targetChain);
    }
}
