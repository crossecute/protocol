// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {HyperlaneMessage} from "src/protocols/hyperlane/HyperlaneMessage.sol";

/// @dev A transmitter has no domain table of its own: it's per-user and locked after
///      creation, so it reads the shared, owner-updatable table on `HyperlaneHubTransceiver`
///      (via `TransmitterBase.transceiver`) live, on every send.
interface IHyperlaneDomainTable {
    function domainFor(bytes32 chainKey) external view returns (uint32);
}

/// @notice Per-user transmitter, created by `HubTransceiverBase.createTransmitter`.
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
        mailbox = mailbox_;
    }

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        return
            HyperlaneMessage.dispatch(
                mailbox, _domainFor(recipient), recipient, payload, attributes, value, _refundTo()
            );
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        return HyperlaneMessage.quote(mailbox, _domainFor(recipient), recipient, payload, attributes, _refundTo());
    }

    bytes4 public constant HYPERLANE_GAS_LIMIT_ATTRIBUTE = HyperlaneMessage.GAS_LIMIT_ATTRIBUTE;

    function supportsAttribute(bytes4 selector) external pure override returns (bool) {
        return selector == HYPERLANE_GAS_LIMIT_ATTRIBUTE;
    }

    function _domainFor(bytes memory recipient) internal view returns (uint32) {
        return IHyperlaneDomainTable(transceiver).domainFor(Erc7930.chainKey(recipient));
    }
}
