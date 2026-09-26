// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMailbox} from "@hyperlane/interfaces/IMailbox.sol";
import {TypeCasts} from "@hyperlane/libs/TypeCasts.sol";
import {StandardHookMetadata} from "@hyperlane/hooks/libs/StandardHookMetadata.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Recipient narrowing, hook metadata, and the `dispatch`/`quoteDispatch` calls,
///         identical across every Hyperlane sender (`HyperlaneTransmitter`,
///         `HyperlaneHubTransceiver`, `HyperlaneSpokeTransceiver`, and the zkSync/Tron
///         spokes).
library HyperlaneMessage {
    bytes4 internal constant GAS_LIMIT_ATTRIBUTE = bytes4(keccak256("crossecute.hyperlane.gasLimit"));

    /// @dev `InterchainGasPaymaster.DEFAULT_GAS_USAGE` at the pinned commit. Restated because
    ///      StandardHookMetadata places `refundAddress` after `gasLimit`, so setting the
    ///      refund target also sets a gas limit, and omitting the attribute must still mean
    ///      the provider's default.
    uint256 internal constant DEFAULT_GAS_LIMIT = 50_000;

    /// @dev Returns zero, ERC-7786's "sent" (see `ProviderHubSendSpec`); the Mailbox's message id
    ///      is in its `DispatchId` event.
    function dispatch(
        address mailbox,
        uint32 domain,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value,
        address refundTo
    ) internal returns (bytes32) {
        IMailbox(mailbox).dispatch{value: value}(
            domain, recipientOf(recipient), payload, hookMetadata(attributes, refundTo)
        );
        return bytes32(0);
    }

    function quote(
        address mailbox,
        uint32 domain,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        address refundTo
    ) internal view returns (uint256) {
        return IMailbox(mailbox)
            .quoteDispatch(domain, recipientOf(recipient), payload, hookMetadata(attributes, refundTo));
    }

    function recipientOf(bytes memory recipient) internal pure returns (bytes32) {
        return TypeCasts.addressToBytes32(ProviderAddress.evmRecipient(recipient));
    }

    /// @dev Without an explicit `refundAddress`, the IGP and ProtocolFee hooks refund
    ///      overpayment to the message sender, i.e. the contract calling `dispatch`. A hub or
    ///      spoke has no `receive`, so that refund would revert the send; a transmitter would
    ///      keep the payer's excess. `refundTo` is `OutboundBase._refundTo()`.
    function hookMetadata(bytes[] memory attributes, address refundTo) internal pure returns (bytes memory) {
        return StandardHookMetadata.formatMetadata(0, gasLimitFrom(attributes), refundTo, "");
    }

    /// @notice One attribute: the destination gas limit, as
    ///         `abi.encodePacked(GAS_LIMIT_ATTRIBUTE, abi.encode(gasLimit))`. Anything else
    ///         is refused per ERC-7786.
    function gasLimitFrom(bytes[] memory attributes) internal pure returns (uint256) {
        return ProviderAttribute.uintValue(attributes, GAS_LIMIT_ATTRIBUTE, type(uint256).max, DEFAULT_GAS_LIMIT);
    }
}
