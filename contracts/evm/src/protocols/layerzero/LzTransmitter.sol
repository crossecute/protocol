// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice The per-user LayerZero transmitter on the home chain, cloned by
///         `TransmitterFactory`.
///
/// @dev It holds no registry pointer and knows no eids. `send(8453, calls)` derives the
///      destination chainKey purely and hands it to `_sendMessage`; the provider binding is
///      what turns that into an endpoint id. A user adding a destination changes nothing
///      here.
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
    /// @dev THIS IS THE SEAM, and it is the same one `LzHubTransceiver` uses for
    ///      `_checkAdmin`. Today the authority is `OwnableUpgradeable`, declared right
    ///      here rather than in the base. When this contract becomes an actual OApp the
    ///      inheritance list gains `OAppUpgradeable` and these two bodies answer from
    ///      OApp's own `Ownable` instead, one line each, and nothing in `TransmitterBase`
    ///      changes, because it never had an opinion about ownership to begin with.
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
}
