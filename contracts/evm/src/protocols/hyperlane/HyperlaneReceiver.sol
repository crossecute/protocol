// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {IMessageRecipient} from "@hyperlane/interfaces/IMessageRecipient.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Per-user account on a non-home chain.
/// @dev Implements `IMessageRecipient.handle` directly, gated `onlyRole(GATEWAY_ROLE)`,
///      rather than inheriting `MailboxClient` (OZ 4.9.3) or `Router`, whose
///      enrolled-router-per-domain check would bypass the registry's provenance dial. See
///      `docs/provider-research.md#5-hyperlane-as-a-native-binding`.
///
/// @dev Implements no `interchainSecurityModule()`, so `Mailbox.recipientIsm` falls back to
///      the Mailbox's `defaultIsm`, which the Mailbox owner can change.
contract HyperlaneReceiver is ReceiverBase, IMessageRecipient {
    /// @notice Hyperlane Mailbox on this chain. Set on the implementation; safe because the
    ///         implementation address lives in the proxy's ERC-1967 slot, not its initcode,
    ///         so this never moves a derived account address.
    address public immutable mailbox;

    constructor(address mailbox_) {
        mailbox = mailbox_;
    }

    /// @dev `grantRole` is `onlyInitializing`, so this initializer is the only window the
    ///      Mailbox's gateway grant ever gets.
    function initialize(address sourceTransmitter_, Call[] calldata calls) external override initializer {
        grantRole(GATEWAY_ROLE, mailbox);
        __ReceiverBase_init(sourceTransmitter_, calls);
    }

    /// @dev `Mailbox.process` verifies the message against its ISM, not which contract sent
    ///      it, so `_onMessageFrom` is the only sender check: no R3.3 exception.
    function handle(
        uint32,
        /* origin */
        bytes32 sender,
        bytes calldata message
    )
        external
        payable
        override
        onlyRole(GATEWAY_ROLE)
    {
        _onMessageFrom(ProviderAddress.evmSender(sender), message);
    }
}
