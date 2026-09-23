// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice Per-user transmitter, created by `HubTransceiverBase.createTransmitter`.
/// @dev No Wormhole code inherited yet; `_sendMessage` still reverts. Targets the Relayer,
///      not bare Core: only `IWormholeRelayer.sendPayloadToEvm` names a destination and
///      prices the round trip on-chain. See
///      `docs/provider-research.md#6-wormhole-core-vs-the-relayer-two-different-bindings`.
contract WormholeTransmitter is TransmitterBase, OwnableUpgradeable {
    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    /// @dev Stays plain `OwnableUpgradeable`: neither `IWormholeRelayer` nor
    ///      `IWormholeReceiver` carries an ownership opinion.
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

    /// @notice No gateway granted yet. A real binding grants `GATEWAY_ROLE` to the Wormhole
    ///         Relayer on `WormholeHubTransceiver`; the transmitter itself has no `Roles` to
    ///         hold it (R3.1 is answered by having no inbound entry point at all).
}
