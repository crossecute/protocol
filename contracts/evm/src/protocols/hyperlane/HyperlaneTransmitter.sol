// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice The per-user transmitter on the home chain, created by
///         `HubTransceiverBase.createTransmitter`.
///
/// @dev IT IS STRUCTURE WITHOUT AN SDK BEHIND IT. No Hyperlane code is inherited and
///      `_sendMessage` still reverts `SendNotImplemented`; what exists is the ownership seam
///      answered and nothing else. See
///      `docs/provider-research.md#5-hyperlane-as-a-native-binding` for what a real binding
///      owes, and `docs/provider-spec.md` for the normative rules.
///
/// @dev PLAIN `OwnableUpgradeable`, DELIBERATELY, AND FOR A DIFFERENT REASON THAN CCIP'S.
///      Hyperlane's own client contracts (`MailboxClient`, `Router`) bring their OWN
///      `OwnableUpgradeable` — but from OpenZeppelin 4.9.3, not this repo's pinned 5.4.0.
///      `MailboxClient._MailboxClient_initialize` calls `__Ownable_init()` with NO argument,
///      which is 4.x's signature; 5.x's takes an explicit initial owner and has no
///      zero-argument overload. The two cannot occupy one inheritance graph. See
///      `docs/provider-research.md#5-hyperlane-as-a-native-binding` for why a real binding
///      does not inherit `MailboxClient` at all, on either side, for this reason.
contract HyperlaneTransmitter is TransmitterBase, OwnableUpgradeable {
    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        // `__Ownable_init` rejects the zero owner itself, with `OwnableInvalidOwner`.
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    /// @notice Where `TransmitterBase`'s ownership requirement is satisfied.
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

    /// @notice NO GATEWAY IS GRANTED, so this transmitter sends through nothing. A real
    ///         binding grants `GATEWAY_ROLE` to the Hyperlane Mailbox on
    ///         `HyperlaneHubTransceiver`, and the transmitter itself never touches the role at
    ///         all: `TransmitterBase` does not inherit `Roles`, because R3.1 ("the transmitter
    ///         MUST reject inbound messages") is answered structurally here rather than by a
    ///         grant. It has no `receiveMessage`, no `commit`, and no `GATEWAY_ROLE` to hold.
}
