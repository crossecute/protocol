// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice The per-user transmitter on the home chain, created by
///         `HubTransceiverBase.createTransmitter`.
///
/// @dev IT IS STRUCTURE WITHOUT AN SDK BEHIND IT. No OP Stack code is inherited and
///      `_sendMessage` still reverts `SendNotImplemented`; what exists is the ownership seam
///      answered and nothing else. See
///      `docs/provider-research.md#7-op-stack-as-a-native-binding` for what a real binding
///      owes, and `docs/provider-spec.md` for the normative rules.
///
/// @dev BINDS TO `ICrossDomainMessenger`, NOT `OptimismPortal`. The messenger un-aliases an
///      inbound sender for you, through `xDomainMessageSender()`; a binding built directly on
///      the portal would have to undo `AddressAliasHelper`'s offset itself
///      (`AddressDerive.undoL1ToL2Alias` exists in this repo for exactly that, and stays
///      unused by this binding for exactly that reason).
contract OpStackTransmitter is TransmitterBase, OwnableUpgradeable {
    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        // `__Ownable_init` rejects the zero owner itself, with `OwnableInvalidOwner`.
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    /// @notice Where `TransmitterBase`'s ownership requirement is satisfied.
    ///
    /// @dev PLAIN `OwnableUpgradeable`, THE SAME CONCLUSION AS CCIP, HYPERLANE, AND WORMHOLE.
    ///      `ICrossDomainMessenger` carries no ownership opinion, no storage, and no external
    ///      dependency at all: a binding holds the messenger's address as its own immutable
    ///      and calls it directly. There is no SDK `Ownable` to merge with here, unlike
    ///      LayerZero's OApp.
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
    ///         binding grants `GATEWAY_ROLE` to the `CrossDomainMessenger` on
    ///         `OpStackHubTransceiver`, and the transmitter itself never touches the role at
    ///         all: `TransmitterBase` does not inherit `Roles`, because R3.1 ("the transmitter
    ///         MUST reject inbound messages") is answered structurally here rather than by a
    ///         grant. It has no `receiveMessage`, no `commit`, and no `GATEWAY_ROLE` to hold.
}
