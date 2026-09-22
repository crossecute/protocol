// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice Per-user transmitter, created by `HubTransceiverBase.createTransmitter`.
/// @dev No CCIP code inherited yet; `_sendMessage` still reverts. See
///      `docs/provider-research.md#4-ccip-as-a-native-binding`.
contract CcipTransmitter is TransmitterBase, OwnableUpgradeable {
    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    /// @dev Stays plain `OwnableUpgradeable` once wired: `CCIPReceiver` carries no ownership
    ///      opinion, and a transmitter never receives, so it never inherits it either way.
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

    /// @notice No gateway granted. A real binding grants `GATEWAY_ROLE` to the CCIP Router on
    ///         `CcipHubTransceiver`; the transmitter itself has no `Roles` to hold it (R3.1 is
    ///         answered by having no inbound entry point at all).
}
