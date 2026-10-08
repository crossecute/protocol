// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {OpStackMessage} from "src/protocols/op-stack/OpStackMessage.sol";
import {providerIdOf} from "src/protocols/ProviderChainId.sol";

/// @notice Per-user transmitter for `op-stack-l1-l2`, created by
///         `TransceiverBase.createTransmitter`. Sends through the messenger its transceiver maps
///         the recipient's chain to.
/// @dev Sender-only: no `receiveOpStackMessage`, so R3.1 is answered by absence rather than a
///      guard. Binds to `ICrossDomainMessenger`, not `OptimismPortal`: the messenger un-aliases
///      the sender, so `AddressDerive.undoL1ToL2Alias` stays unused. See
///      `docs/provider-research.md#7-op-stack-as-a-native-binding`.
contract OpStackTransmitter is OwnableTransmitter {
    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        // forge-lint: disable-next-line(unsafe-typecast) set through the transceiver's address setter
        address messenger = address(uint160(providerIdOf(transceiver, recipient)));
        return OpStackMessage.send(messenger, recipient, payload, attributes, value, _defaultGas(payload));
    }

    /// @dev Zero: see `OpStackMessage`.
    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        providerIdOf(transceiver, recipient);
        return OpStackMessage.quote(recipient, attributes, _defaultGas(payload));
    }

    bytes4 public constant OP_STACK_MIN_GAS_LIMIT_ATTRIBUTE = OpStackMessage.MIN_GAS_LIMIT_ATTRIBUTE;

    function supportsAttribute(bytes4 selector) external pure override returns (bool) {
        return selector == OP_STACK_MIN_GAS_LIMIT_ATTRIBUTE;
    }
}
