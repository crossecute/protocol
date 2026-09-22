// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice Per-user transmitter, created by `HubTransceiverBase.createTransmitter`.
/// @dev No Hyperlane code inherited yet; `_sendMessage` still reverts. See
///      `docs/provider-research.md#5-hyperlane-as-a-native-binding`.
///
/// @dev Plain `OwnableUpgradeable`. Hyperlane's `MailboxClient`/`Router` pin OpenZeppelin
///      4.9.3 (`_MailboxClient_initialize` calls the zero-arg `__Ownable_init()`; this repo
///      is on OZ 5.4.0, whose `__Ownable_init` takes an explicit owner and has no zero-arg
///      overload) — the two cannot share an inheritance graph. A real binding does not
///      inherit `MailboxClient` at all.
contract HyperlaneTransmitter is TransmitterBase, OwnableUpgradeable {
    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    function _owner() internal view override returns (address) {
        return owner();
    }

    function _checkOwner()
        internal
        view
        override(TransmitterBase, OwnableUpgradeable)
    {
        OwnableUpgradeable._checkOwner();
    }

    /// @notice No gateway granted yet. A real binding grants `GATEWAY_ROLE` to the Hyperlane
    ///         Mailbox on `HyperlaneHubTransceiver`; the transmitter itself has no `Roles` to
    ///         hold it (R3.1 is answered by having no inbound entry point at all).
}
