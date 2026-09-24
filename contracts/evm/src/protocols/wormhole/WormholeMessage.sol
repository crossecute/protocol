// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IWormholeRelayer} from "@wormhole-sdk/interfaces/IWormholeRelayer.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice Recipient narrowing, gas-limit attribute parsing, and the Relayer send/quote calls,
///         identical across every Wormhole sender (`WormholeTransmitter`,
///         `WormholeHubTransceiver`, `WormholeSpokeTransceiver`, and the zkSync/Tron spokes).
library WormholeMessage {
    bytes4 internal constant GAS_LIMIT_ATTRIBUTE = bytes4(keccak256("crossecute.wormhole.gasLimit"));

    /// @dev The Relayer has no default: `sendPayloadToEvm` requires a gas limit. Matches
    ///      CCIP's own default; not measured against this protocol's delivery paths.
    uint256 internal constant DEFAULT_GAS_LIMIT = 200_000;

    error UnknownWormholeAttribute(bytes attribute);
    error UnsupportedWormholeRecipient(bytes addr);
    error UnsupportedWormholeSender(bytes32 sourceAddress);
    error AdditionalMessagesNotSupported();
    error InsufficientWormholeValue(uint256 value, uint256 price);
    error RefundFailed();

    /// @dev `sendPayloadToEvm` reverts `InvalidMsgValue` unless paid its quote exactly, so a
    ///      caller padding for price drift would revert rather than be refunded. This pays the
    ///      quote and returns the rest of `value` to `refundTo` (`OutboundBase._refundTo()`).
    ///      Unused destination gas is refunded to the recipient on the target chain; where the
    ///      recipient has no `receive` (a transceiver) the Relayer keeps it, as it would by
    ///      default.
    function send(
        address relayer,
        uint16 targetChain,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value,
        address refundTo
    ) internal returns (bytes32) {
        uint256 gasLimit = gasLimitFrom(attributes);
        (uint256 price,) = IWormholeRelayer(relayer).quoteEVMDeliveryPrice(targetChain, 0, gasLimit);
        if (value < price) revert InsufficientWormholeValue(value, price);
        uint64 sequence = _sendPayload(relayer, targetChain, recipientOf(recipient), payload, gasLimit, price);
        if (value > price) {
            (bool ok,) = refundTo.call{value: value - price}("");
            if (!ok) revert RefundFailed();
        }
        return bytes32(uint256(sequence));
    }

    /// @dev Split out of `send` for stack depth under the legacy (non-IR) pipeline.
    function _sendPayload(
        address relayer,
        uint16 targetChain,
        address target,
        bytes memory payload,
        uint256 gasLimit,
        uint256 price
    ) private returns (uint64) {
        return IWormholeRelayer(relayer).sendPayloadToEvm{value: price}(
            targetChain, target, payload, 0, gasLimit, targetChain, target
        );
    }

    function quote(address relayer, uint16 targetChain, bytes memory recipient, bytes[] memory attributes)
        internal
        view
        returns (uint256 price)
    {
        recipientOf(recipient);
        (price,) = IWormholeRelayer(relayer).quoteEVMDeliveryPrice(targetChain, 0, gasLimitFrom(attributes));
    }

    /// @dev `sendPayloadToEvm` takes an `address`; anything but 20 bytes would be silently
    ///      truncated or padded by the cast.
    function recipientOf(bytes memory recipient) internal pure returns (address) {
        bytes memory addr = Erc7930.parseStrict(recipient).addr;
        if (addr.length != 20) revert UnsupportedWormholeRecipient(addr);
        return address(bytes20(addr));
    }

    /// @dev Wormhole-format addresses are left-padded; nonzero high bytes are not an EVM
    ///      sender and must not be truncated into one.
    function senderOf(bytes32 sourceAddress) internal pure returns (address) {
        if (uint256(sourceAddress) > type(uint160).max) revert UnsupportedWormholeSender(sourceAddress);
        return address(uint160(uint256(sourceAddress)));
    }

    /// @dev Batched VAAs (e.g. CCTP) are never requested by this binding's sends, so a delivery
    ///      carrying any did not originate from one.
    function requireNoAdditionalMessages(bytes[] calldata additionalMessages) internal pure {
        if (additionalMessages.length != 0) revert AdditionalMessagesNotSupported();
    }

    /// @notice One attribute: the destination gas limit, as
    ///         `abi.encodePacked(GAS_LIMIT_ATTRIBUTE, abi.encode(gasLimit))`. Anything else
    ///         is refused per ERC-7786.
    function gasLimitFrom(bytes[] memory attributes) internal pure returns (uint256) {
        if (attributes.length == 0) return DEFAULT_GAS_LIMIT;
        if (attributes.length > 1) revert UnknownWormholeAttribute(attributes[1]);
        bytes memory attribute = attributes[0];
        if (attribute.length != 36) revert UnknownWormholeAttribute(attribute);
        bytes4 selector;
        uint256 gasLimit;
        assembly {
            selector := mload(add(attribute, 32))
            gasLimit := mload(add(attribute, 36))
        }
        if (selector != GAS_LIMIT_ATTRIBUTE) revert UnknownWormholeAttribute(attribute);
        return gasLimit;
    }
}
