// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice The per-user transmitter on the home chain, created by
///         `HubTransceiverBase.createTransmitter`.
///
/// @dev IT IS STRUCTURE WITHOUT AN SDK BEHIND IT. No Wormhole code is inherited and
///      `_sendMessage` still reverts `SendNotImplemented`; what exists is the ownership seam
///      answered and nothing else. See
///      `docs/provider-research.md#6-wormhole-core-vs-the-relayer-two-different-bindings`
///      for what a real binding owes, and `docs/provider-spec.md` for the normative rules.
///
/// @dev TARGETS THE RELAYER, NOT BARE CORE. `IWormholeRelayer.sendPayloadToEvm` names an
///      explicit destination and prices the full round trip in this chain's native currency;
///      bare `IWormhole.publishMessage` does neither, and a bare-Core transmitter would have
///      no on-chain quote to answer `_quoteMessage` with at all. See the research note for
///      why these are two different bindings, not two configurations of one.
contract WormholeTransmitter is TransmitterBase, OwnableUpgradeable {
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
    /// @dev PLAIN `OwnableUpgradeable`, AND NOTHING ABOUT THAT CHANGES WHEN THIS IS WIRED IN.
    ///      Neither `IWormholeRelayer` nor `IWormholeReceiver` carries an ownership opinion at
    ///      all: a relayer binding holds the relayer's address as its own immutable and
    ///      implements the receive interface directly, the same shape settled for CCIP and
    ///      Hyperlane. There is no SDK `Ownable` to merge with here, unlike LayerZero's OApp.
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
    ///         binding grants `GATEWAY_ROLE` to the Wormhole Relayer on
    ///         `WormholeHubTransceiver`, and the transmitter itself never touches the role at
    ///         all: `TransmitterBase` does not inherit `Roles`, because R3.1 ("the transmitter
    ///         MUST reject inbound messages") is answered structurally here rather than by a
    ///         grant. It has no `receiveMessage`, no `commit`, and no `GATEWAY_ROLE` to hold.
}
