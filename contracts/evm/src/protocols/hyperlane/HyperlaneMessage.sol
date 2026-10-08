// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMailbox} from "@hyperlane/interfaces/IMailbox.sol";
import {TypeCasts} from "@hyperlane/libs/TypeCasts.sol";
import {StandardHookMetadata} from "@hyperlane/hooks/libs/StandardHookMetadata.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Recipient narrowing, hook metadata, and the `dispatch`/`quoteDispatch` calls,
///         identical across every Hyperlane sender (`HyperlaneTransmitter`,
///         `HyperlaneTransceiver`, and its zkSync/Tron variants).
library HyperlaneMessage {
    error NoHyperlaneRoute(uint32 domain);

    // forge-lint: disable-next-line(unsafe-typecast) a selector is the hash's first 4 bytes
    bytes4 internal constant GAS_LIMIT_ATTRIBUTE = bytes4(keccak256("crossecute.hyperlane.gasLimit"));

    /// @dev Returns zero, ERC-7786's "sent" (see `ProviderSendSpec`); the Mailbox's message id
    ///      is in its `DispatchId` event.
    function dispatch(
        address mailbox,
        uint32 domain,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value,
        address refundTo,
        uint256 defaultGas
    ) internal returns (bytes32) {
        quote(mailbox, domain, recipient, payload, attributes, refundTo, defaultGas);
        // The message id is in the mailbox's event; sends return 0.
        // forge-lint: disable-start(unused-return)
        IMailbox(mailbox).dispatch{value: value}(
            domain, recipientOf(recipient), payload, hookMetadata(attributes, refundTo, defaultGas)
        );
        // forge-lint: disable-end(unused-return)
        return bytes32(0);
    }

    /// @dev A domain the Mailbox's default hook does not route falls back to a hook that charges
    ///      nothing and pays no relayer, so its dispatch succeeds and is never delivered (#56).
    ///      Zero is never a real quote, so it is refused here, which `dispatch` runs first.
    function quote(
        address mailbox,
        uint32 domain,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        address refundTo,
        uint256 defaultGas
    ) internal view returns (uint256 fee) {
        fee = IMailbox(mailbox)
            .quoteDispatch(domain, recipientOf(recipient), payload, hookMetadata(attributes, refundTo, defaultGas));
        if (fee == 0) revert NoHyperlaneRoute(domain);
    }

    function recipientOf(bytes memory recipient) internal pure returns (bytes32) {
        return TypeCasts.addressToBytes32(ProviderAddress.evmRecipient(recipient));
    }

    /// @dev Without an explicit `refundAddress`, the IGP and ProtocolFee hooks refund
    ///      overpayment to the message sender, i.e. the contract calling `dispatch`, and a
    ///      transmitter or a transceiver would keep the payer's excess. `refundTo` is
    ///      `OutboundBase._refundTo()`.
    function hookMetadata(bytes[] memory attributes, address refundTo, uint256 defaultGas)
        internal
        pure
        returns (bytes memory)
    {
        return StandardHookMetadata.formatMetadata(0, gasLimitFrom(attributes, defaultGas), refundTo, "");
    }

    /// @notice One attribute: the destination gas limit, as
    ///         `abi.encodePacked(GAS_LIMIT_ATTRIBUTE, abi.encode(gasLimit))`. Anything else
    ///         is refused per ERC-7786.
    function gasLimitFrom(bytes[] memory attributes, uint256 defaultGas) internal pure returns (uint256) {
        return ProviderAttribute.uintValue(attributes, GAS_LIMIT_ATTRIBUTE, type(uint256).max, defaultGas);
    }
}
