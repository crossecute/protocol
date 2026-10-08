// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Client} from "@ccip/libraries/Client.sol";
import {IRouterClient} from "@ccip/interfaces/IRouterClient.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Send, quote, and `EVM2AnyMessage` construction for every CCIP sender (transmitter,
///         and the transceiver and its variants). The id `ccipSend` returns is discarded: senders
///         return a zero sendId, ERC-7786's "sent" (see `ProviderSendSpec`); the id is in
///         the on-ramp's send event.
library CcipMessage {
    // forge-lint: disable-next-line(unsafe-typecast) a selector is the hash's first 4 bytes
    bytes4 internal constant EXTRA_ARGS_ATTRIBUTE = bytes4(keccak256("crossecute.ccip.extraArgs"));

    /// @notice The EVM sender of a delivered message.
    /// @dev `abi.decode` reverts on a word with bits above the low 20 bytes set, so a wider
    ///      sender is refused rather than truncated (C10).
    function sender(Client.Any2EVMMessage calldata message) internal pure returns (address) {
        return abi.decode(message.sender, (address));
    }

    function send(
        address router,
        uint64 selector,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value,
        uint256 defaultGas
    ) internal {
        // forge-lint: disable-next-line(unused-return) the id is in the on-ramp's event; sends return 0
        IRouterClient(router).ccipSend{value: value}(selector, build(recipient, payload, attributes, defaultGas));
    }

    function quote(
        address router,
        uint64 selector,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 defaultGas
    ) internal view returns (uint256) {
        return IRouterClient(router).getFee(selector, build(recipient, payload, attributes, defaultGas));
    }

    function build(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 defaultGas)
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
            extraArgs: extraArgsFrom(attributes, defaultGas)
        });
    }

    /// @notice One attribute: CCIP's `EVMExtraArgsV2`, as
    ///         `abi.encodePacked(EXTRA_ARGS_ATTRIBUTE, abi.encode(gasLimit,
    ///         allowOutOfOrderExecution))`. Anything else is refused per ERC-7786.
    /// @dev Without it, `defaultGas` in order, which is what empty `extraArgs` would mean but
    ///      at CCIP's own 200k.
    function extraArgsFrom(bytes[] memory attributes, uint256 defaultGas) internal pure returns (bytes memory) {
        (bool present, bytes memory encoded) = ProviderAttribute.body(attributes, EXTRA_ARGS_ATTRIBUTE, 64);
        // In order, as empty `extraArgs` would be.
        // forge-lint: disable-start(boolean-cst)
        (uint256 gasLimit, bool allowOutOfOrderExecution) =
            present ? abi.decode(encoded, (uint256, bool)) : (defaultGas, false);
        // forge-lint: disable-end(boolean-cst)
        return Client._argsToBytes(
            Client.EVMExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: allowOutOfOrderExecution})
        );
    }
}
