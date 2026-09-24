// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMailbox} from "@hyperlane/interfaces/IMailbox.sol";
import {TypeCasts} from "@hyperlane/libs/TypeCasts.sol";
import {StandardHookMetadata} from "@hyperlane/hooks/libs/StandardHookMetadata.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

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

    error UnknownHyperlaneAttribute(bytes attribute);
    error UnsupportedHyperlaneRecipient(bytes addr);

    function dispatch(
        address mailbox,
        uint32 domain,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value,
        address refundTo
    ) internal returns (bytes32) {
        return IMailbox(mailbox).dispatch{value: value}(
            domain, recipientOf(recipient), payload, hookMetadata(attributes, refundTo)
        );
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

    /// @dev EVM recipients only: anything but 20 bytes would be silently truncated or padded
    ///      by the cast into a different `bytes32` recipient.
    function recipientOf(bytes memory recipient) internal pure returns (bytes32) {
        bytes memory addr = Erc7930.parseStrict(recipient).addr;
        if (addr.length != 20) revert UnsupportedHyperlaneRecipient(addr);
        return TypeCasts.addressToBytes32(address(bytes20(addr)));
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
        if (attributes.length == 0) return DEFAULT_GAS_LIMIT;
        if (attributes.length > 1) revert UnknownHyperlaneAttribute(attributes[1]);
        bytes memory attribute = attributes[0];
        if (attribute.length != 36) revert UnknownHyperlaneAttribute(attribute);
        bytes4 selector;
        uint256 gasLimit;
        assembly {
            selector := mload(add(attribute, 32))
            gasLimit := mload(add(attribute, 36))
        }
        if (selector != GAS_LIMIT_ATTRIBUTE) revert UnknownHyperlaneAttribute(attribute);
        return gasLimit;
    }
}
