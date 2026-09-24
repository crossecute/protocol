// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICrossDomainMessenger} from "@optimism/interfaces/universal/ICrossDomainMessenger.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";

/// @notice The inbound entry point every OP Stack binding contract exposes. `sendMessage`
///         delivers `abi.encodeCall(receiveOpStackMessage, (payload))` as the target's calldata.
interface IOpStackRecipient {
    function receiveOpStackMessage(bytes calldata payload) external;
}

/// @notice Send and inbound-sender logic shared by every OP Stack binding contract.
///
/// @dev No native fee: an L1->L2 deposit pays for its L2 gas by burning L1 gas in the sending
///      transaction (`ResourceMetering`), and an L2->L1 message pays nothing at the source.
///      `sendMessage`'s `msg.value` is bridged to the target, not spent, so `value` must be
///      zero and the quote is zero.
library OpStackMessage {
    bytes4 internal constant MIN_GAS_LIMIT_ATTRIBUTE = bytes4(keccak256("crossecute.opstack.minGasLimit"));

    /// @dev `sendMessage` requires a gas limit for the target call. Underestimating is
    ///      recoverable: the messenger records the relay in `failedMessages` and anyone can
    ///      replay it with more gas. Not measured against this protocol's delivery paths.
    uint32 internal constant DEFAULT_MIN_GAS_LIMIT = 200_000;

    error OpStackValueNotSupported(uint256 value);
    error NotThisMessengersChain(bytes32 chainKey, bytes32 messengerChainKey);
    error UnsupportedOpStackRecipient(bytes addr);

    /// @param messengerChainKey The one chain `messenger` reaches. The destination is which
    ///        messenger is called, not an argument to it, so a recipient on any other chain
    ///        would otherwise be delivered to the same address on this one.
    /// @return Zero, ERC-7786's "sent" (see `ProviderHubSendSpec`); the messenger's nonce is in
    ///         its `SentMessage` event.
    function send(
        address messenger,
        bytes32 messengerChainKey,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value
    ) internal returns (bytes32) {
        address target = _check(messengerChainKey, recipient, value);
        ICrossDomainMessenger(messenger)
            .sendMessage(
                target, abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, (payload)), minGasLimitFrom(attributes)
            );
        return bytes32(0);
    }

    /// @dev Zero, after the same checks `send` applies, so it reverts wherever the send would.
    function quote(bytes32 messengerChainKey, bytes memory recipient, bytes[] memory attributes)
        internal
        pure
        returns (uint256)
    {
        _check(messengerChainKey, recipient, 0);
        minGasLimitFrom(attributes);
        return 0;
    }

    /// @notice The origin-chain sender of the message being relayed.
    /// @dev The only authenticated sender: `sendMessage` is permissionless, so every byte of the
    ///      delivered calldata was chosen by whoever sent it. Read from the caller, which the
    ///      entry point has already required to hold `GATEWAY_ROLE`.
    function sender() internal view returns (address) {
        return ICrossDomainMessenger(msg.sender).xDomainMessageSender();
    }

    function _check(bytes32 messengerChainKey, bytes memory recipient, uint256 value) private pure returns (address) {
        if (value != 0) revert OpStackValueNotSupported(value);
        bytes32 chainKey = Erc7930.chainKey(recipient);
        if (chainKey != messengerChainKey) revert NotThisMessengersChain(chainKey, messengerChainKey);
        bytes memory addr = Erc7930.parseStrict(recipient).addr;
        if (addr.length != 20) revert UnsupportedOpStackRecipient(addr);
        return address(bytes20(addr));
    }

    /// @notice One attribute: the target's minimum gas, as
    ///         `abi.encodePacked(MIN_GAS_LIMIT_ATTRIBUTE, abi.encode(minGasLimit))`, at most
    ///         `type(uint32).max`. Anything else is refused per ERC-7786.
    function minGasLimitFrom(bytes[] memory attributes) internal pure returns (uint32) {
        return uint32(
            ProviderAttribute.uintValue(attributes, MIN_GAS_LIMIT_ATTRIBUTE, type(uint32).max, DEFAULT_MIN_GAS_LIMIT)
        );
    }
}
