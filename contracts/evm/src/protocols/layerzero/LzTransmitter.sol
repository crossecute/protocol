// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice The per-user transmitter on the home chain, created by
///         `HubTransceiverBase.createTransmitter`.
///
/// @dev IT IS STRUCTURE WITHOUT AN SDK BEHIND IT. No LayerZero code is inherited and
///      `_sendMessage` still reverts `SendNotImplemented`; what exists is the ownership seam
///      answered and nothing else. See `docs/provider-spec.md` for what a real binding owes.
contract LzTransmitter is TransmitterBase, OwnableUpgradeable {
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
    /// @dev THE SEAM, and the same one `LzHubTransceiver` uses for `isAdmin`. When this
    ///      becomes an actual OApp the inheritance list gains `OAppUpgradeable` and these two
    ///      bodies answer from OApp's own `Ownable` instead, one line each; nothing in
    ///      `TransmitterBase` changes, because it never had an opinion about ownership.
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
    ///         binding grants `GATEWAY_ROLE` to the endpoint on `LzHubTransceiver`, and the
    ///         transmitter itself never touches the role at all: `TransmitterBase` does not
    ///         inherit `Roles`, because R3.1 ("the transmitter MUST reject inbound messages")
    ///         is answered structurally here rather than by a grant. It has no
    ///         `receiveMessage`, no `commit`, and no `GATEWAY_ROLE` to hold. If `OAppUpgradeable`
    ///         brings an inbound entry point onto this contract when it becomes real, R3.1
    ///         says to override it and revert, never to wire it up.

}
