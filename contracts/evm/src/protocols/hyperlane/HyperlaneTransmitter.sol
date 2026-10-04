// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {HyperlaneMessage} from "src/protocols/hyperlane/HyperlaneMessage.sol";
import {providerIdOf} from "src/protocols/ProviderChainId.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Per-user transmitter, created by `TransceiverBase.createTransmitter`.
/// @dev Sender-only: no `handle` implemented, so R3.1 is answered by absence rather than a
///      guard. Plain `OwnableUpgradeable`, not Hyperlane's `MailboxClient`, which pins OZ
///      4.9.3's zero-arg `__Ownable_init()` (see
///      `docs/provider-research.md#5-hyperlane-as-a-native-binding`).
contract HyperlaneTransmitter is OwnableTransmitter {
    /// @notice Hyperlane Mailbox on this chain. Set on the implementation; safe because the
    ///         implementation address lives in the proxy's ERC-1967 slot, not its initcode,
    ///         so this never moves a derived account address.
    address public immutable mailbox;

    constructor(address mailbox_) {
        if (mailbox_ == address(0)) revert ProviderAddress.ZeroEndpoint();
        mailbox = mailbox_;
    }

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint32 setter
        uint32 domain = uint32(providerIdOf(transceiver, recipient));
        return HyperlaneMessage.dispatch(mailbox, domain, recipient, payload, attributes, value, _refundTo());
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint32 setter
        uint32 domain = uint32(providerIdOf(transceiver, recipient));
        return HyperlaneMessage.quote(mailbox, domain, recipient, payload, attributes, _refundTo());
    }

    bytes4 public constant HYPERLANE_GAS_LIMIT_ATTRIBUTE = HyperlaneMessage.GAS_LIMIT_ATTRIBUTE;

    function supportsAttribute(bytes4 selector) external pure override returns (bool) {
        return selector == HYPERLANE_GAS_LIMIT_ATTRIBUTE;
    }
}
