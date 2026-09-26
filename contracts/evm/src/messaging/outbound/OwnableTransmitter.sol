// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice `TransmitterBase` with OpenZeppelin's `Ownable` as its authority, which every
///         binding uses. `TransmitterBase` itself stays ownership-agnostic (see its note).
abstract contract OwnableTransmitter is TransmitterBase, OwnableUpgradeable {
    /// @dev The `ITransmitterInit` shape `HubTransceiverBase` encodes.
    function initialize(address owner_, address transceiver_, bytes32 salt_) external virtual initializer {
        __OwnableTransmitter_init(owner_, transceiver_, salt_);
    }

    function __OwnableTransmitter_init(address owner_, address transceiver_, bytes32 salt_)
        internal
        onlyInitializing
    {
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    function _owner() internal view override returns (address) {
        return owner();
    }

    function _checkOwner() internal view virtual override(TransmitterBase, OwnableUpgradeable) {
        OwnableUpgradeable._checkOwner();
    }
}
