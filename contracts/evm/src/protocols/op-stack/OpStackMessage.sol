// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICrossDomainMessenger} from "@optimism/interfaces/universal/ICrossDomainMessenger.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice The inbound entry point every OP Stack binding contract exposes. `sendMessage`
///         delivers `abi.encodeCall(receiveOpStackMessage, (payload))` as the target's calldata.
interface IOpStackRecipient {
    function receiveOpStackMessage(bytes calldata payload) external;
}

/// @notice Send and inbound-sender logic shared by every `op-stack-l1-l2` contract, over
///         `CrossDomainMessenger`.
///
/// @dev No native fee: an L1->L2 deposit pays for its L2 gas by burning L1 gas in the sending
///      transaction (`ResourceMetering`), and an L2->L1 message pays nothing at the source.
///      The messenger's `sendMessage` bridges its `msg.value` to the target rather than
///      spending it, so `value` must be zero and the quote is zero.
library OpStackMessage {
    // forge-lint: disable-next-line(unsafe-typecast) a selector is the hash's first 4 bytes
    bytes4 internal constant MIN_GAS_LIMIT_ATTRIBUTE = bytes4(keccak256("crossecute.opstack.minGasLimit"));

    error OpStackValueNotSupported(uint256 value);

    /// @param messenger The messenger for the recipient's chain, from the transceiver's table:
    ///        the destination is which messenger is called, not an argument to it.
    /// @return Zero, ERC-7786's "sent" (see `ProviderSendSpec`); the messenger's nonce is in
    ///         its `SentMessage` event.
    function send(
        address messenger,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value,
        uint256 defaultGas
    ) internal returns (bytes32) {
        address target = _check(recipient, value);
        ICrossDomainMessenger(messenger)
            .sendMessage(
                target,
                abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, (payload)),
                minGasLimitFrom(attributes, defaultGas)
            );
        return bytes32(0);
    }

    /// @dev Zero, after the same checks `send` applies. The caller has already looked up the
    ///      messenger, which reverts for a chain the table does not map.
    function quote(bytes memory recipient, bytes[] memory attributes, uint256 defaultGas)
        internal
        pure
        returns (uint256)
    {
        _check(recipient, 0);
        minGasLimitFrom(attributes, defaultGas);
        return 0;
    }

    /// @notice The origin-chain sender of the message being relayed.
    /// @dev The only authenticated sender: `sendMessage` is permissionless, so every byte of the
    ///      delivered calldata was chosen by whoever sent it. Read from the caller, which the
    ///      entry point has already required to hold `GATEWAY_ROLE`.
    function sender() internal view returns (address) {
        return ICrossDomainMessenger(msg.sender).xDomainMessageSender();
    }

    function _check(bytes memory recipient, uint256 value) private pure returns (address) {
        if (value != 0) revert OpStackValueNotSupported(value);
        return ProviderAddress.evmRecipient(recipient);
    }

    /// @notice One attribute: the target's minimum gas, as
    ///         `abi.encodePacked(MIN_GAS_LIMIT_ATTRIBUTE, abi.encode(minGasLimit))`, at most
    ///         `type(uint32).max`. Anything else is refused per ERC-7786.
    /// @dev An underestimate is recoverable: the messenger records the failed relay and anyone
    ///      can replay it with more gas.
    function minGasLimitFrom(bytes[] memory attributes, uint256 defaultGas) internal pure returns (uint32) {
        uint256 v = ProviderAttribute.uintValue(attributes, MIN_GAS_LIMIT_ATTRIBUTE, type(uint32).max, defaultGas);
        // forge-lint: disable-next-line(unsafe-typecast) bounded by uintValue
        return uint32(v);
    }
}
