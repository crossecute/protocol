// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Client} from "@ccip/libraries/Client.sol";
import {IRouterClient} from "@ccip/interfaces/IRouterClient.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Send, quote, and `EVM2AnyMessage` construction for every CCIP sender (transmitter,
///         hub, and each spoke variant). The id `ccipSend` returns is discarded: senders
///         return a zero sendId, ERC-7786's "sent" (see `ProviderHubSendSpec`); the id is in
///         the on-ramp's send event.
library CcipMessage {
    bytes4 internal constant EXTRA_ARGS_ATTRIBUTE = bytes4(keccak256("crossecute.ccip.extraArgs"));

    function send(
        address router,
        uint64 selector,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value
    ) internal {
        IRouterClient(router).ccipSend{value: value}(selector, build(recipient, payload, attributes));
    }

    function quote(address router, uint64 selector, bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        returns (uint256)
    {
        return IRouterClient(router).getFee(selector, build(recipient, payload, attributes));
    }

    /// @dev Empty `extraArgs` is a valid default (CCIP's own 200k gas limit applies), not a
    ///      missing one.
    function build(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        pure
        returns (Client.EVM2AnyMessage memory)
    {
        address receiver = ProviderAddress.evmRecipient(recipient);
        Client.EVMTokenAmount[] memory noTokens = new Client.EVMTokenAmount[](0);
        return Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: payload,
            tokenAmounts: noTokens,
            feeToken: address(0),
            extraArgs: extraArgsFrom(attributes)
        });
    }

    /// @notice One attribute: CCIP's `EVMExtraArgsV2`, as
    ///         `abi.encodePacked(EXTRA_ARGS_ATTRIBUTE, abi.encode(gasLimit,
    ///         allowOutOfOrderExecution))`. Anything else is refused per ERC-7786.
    function extraArgsFrom(bytes[] memory attributes) internal pure returns (bytes memory) {
        (bool present, bytes memory encoded) = ProviderAttribute.body(attributes, EXTRA_ARGS_ATTRIBUTE, 64);
        if (!present) return "";
        (uint256 gasLimit, bool allowOutOfOrderExecution) = abi.decode(encoded, (uint256, bool));
        return Client._argsToBytes(
            Client.EVMExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: allowOutOfOrderExecution})
        );
    }
}
