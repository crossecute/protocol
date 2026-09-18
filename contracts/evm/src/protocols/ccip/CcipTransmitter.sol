// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice The per-user transmitter on the home chain, created by
///         `HubTransceiverBase.createTransmitter`.
///
/// @dev IT IS STRUCTURE WITHOUT AN SDK BEHIND IT. No CCIP code is inherited and
///      `_sendMessage` still reverts `SendNotImplemented`; what exists is the ownership seam
///      answered and nothing else. See `docs/provider-research.md#4-ccip-as-a-native-binding`
///      for what a real binding owes, and `docs/provider-spec.md` for the normative rules.
contract CcipTransmitter is TransmitterBase, OwnableUpgradeable {
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
    /// @dev THIS SEAM DOES NOT CHANGE WHEN CCIP IS WIRED IN, UNLIKE THE LAYERZERO TEMPLATE'S.
    ///      Chainlink's `CCIPReceiver` carries no ownership opinion at all: it holds one
    ///      immutable (`i_ccipRouter`) and one modifier (`onlyRouter`), nothing else, and a
    ///      transmitter never receives, so it never inherits `CCIPReceiver` regardless of
    ///      whether it sends through CCIP. `OwnableUpgradeable` stays exactly this.
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
    ///         binding grants `GATEWAY_ROLE` to the CCIP Router on `CcipHubTransceiver`, and
    ///         the transmitter itself never touches the role at all: `TransmitterBase` does
    ///         not inherit `Roles`, because R3.1 ("the transmitter MUST reject inbound
    ///         messages") is answered structurally here rather than by a grant. It has no
    ///         `receiveMessage`, no `commit`, and no `GATEWAY_ROLE` to hold. If a real binding
    ///         ever needs CCIP's `ccipReceive` reachable on this contract for some reason
    ///         (it should not), the correct answer is to override it and revert, never to
    ///         grant a role that does not exist here.
}
