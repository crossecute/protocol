// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice Per-user transmitter, created by `HubTransceiverBase.createTransmitter`.
/// @dev No OP Stack code inherited yet; `_sendMessage` still reverts. Binds to
///      `ICrossDomainMessenger`, not `OptimismPortal` — the messenger un-aliases the sender
///      via `xDomainMessageSender()`, so `AddressDerive.undoL1ToL2Alias` stays unused here
///      (it's for a binding built directly on the portal). See
///      `docs/provider-research.md#7-op-stack-as-a-native-binding`.
contract OpStackTransmitter is TransmitterBase, OwnableUpgradeable {
    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    /// @dev Stays plain `OwnableUpgradeable`: `ICrossDomainMessenger` has no ownership
    ///      opinion, no storage, no external dependency.
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

    /// @notice No gateway granted yet. A real binding grants `GATEWAY_ROLE` to the
    ///         `CrossDomainMessenger` on `OpStackHubTransceiver`; the transmitter itself has
    ///         no `Roles` to hold it (R3.1 is answered by having no inbound entry point).
}
