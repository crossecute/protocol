// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IL2ToL2CrossDomainMessenger} from "@optimism/interfaces/L2/IL2ToL2CrossDomainMessenger.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {IAccountTransceiver} from "src/messaging/outbound/TransmitterBase.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";
import {OpStackMessage, IOpStackRecipient} from "src/protocols/op-stack/OpStackMessage.sol";

/// @notice Send and inbound-context logic shared by every `op-stack-l2-l2` contract, over the
///         Superchain interop `L2ToL2CrossDomainMessenger`. Its contracts take messages at
///         `op-stack-l1-l2`'s entry point, `IOpStackRecipient`, and refuse value with its error.
///
/// @dev No fee and no options: `sendMessage` is not payable and takes no gas limit, since the
///      relay is a separate transaction whose sender chooses the gas. Delivery therefore depends
///      on a relayer. The messenger relays a message once, and a reverted relay can be retried.
///      A target with no code consumes a message as a no-op, which every target here avoids:
///      a send goes to a transceiver or to a receiver that already exists.
library OpStackInteropMessage {
    /// @notice The predeploy, at one address on every OP Stack chain that runs interop.
    address internal constant MESSENGER = 0x4200000000000000000000000000000000000023;

    error InteropToThisChain();

    /// @param routes The transceiver, whose `routeTo` reverts for a chain it has no route to:
    ///        with no id table, the route is what limits a send to the configured chains.
    /// @return Zero, ERC-7786's "sent" (see `ProviderSendSpec`); the messenger's message hash
    ///         is in its `SentMessage` event.
    function send(
        address routes,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value
    ) internal returns (bytes32) {
        (uint256 destination, address target) = _check(routes, recipient, attributes, value);
        bytes memory message = abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, (payload));
        // forge-lint: disable-next-line(unused-return) the hash is in the messenger's event; sends return 0
        IL2ToL2CrossDomainMessenger(MESSENGER).sendMessage(destination, target, message);
        return bytes32(0);
    }

    /// @dev Zero, after the same checks `send` applies, so it reverts wherever the send would.
    function quote(address routes, bytes memory recipient, bytes[] memory attributes) internal view returns (uint256) {
        _check(routes, recipient, attributes, 0);
        return 0;
    }

    /// @notice The origin-chain sender and chain of the message being relayed.
    /// @dev The only authenticated origin: `sendMessage` is permissionless, so every byte of
    ///      the delivered calldata was chosen by whoever sent it. Read from the caller, which
    ///      the entry point has already required to hold `GATEWAY_ROLE`.
    function context() internal view returns (address sender, uint256 source) {
        return IL2ToL2CrossDomainMessenger(msg.sender).crossDomainMessageContext();
    }

    function _check(address routes, bytes memory recipient, bytes[] memory attributes, uint256 value)
        private
        view
        returns (uint256 destination, address target)
    {
        if (value != 0) revert OpStackMessage.OpStackValueNotSupported(value);
        ProviderAttribute.none(attributes);
        // forge-lint: disable-next-line(unused-return) called for its revert on an unrouted chain
        IAccountTransceiver(routes).routeTo(Erc7930.chainKey(recipient));
        destination = Erc7930.evmChainId(Erc7930.parseStrict(recipient));
        if (destination == block.chainid) revert InteropToThisChain();
        target = ProviderAddress.evmRecipient(recipient);
    }
}
