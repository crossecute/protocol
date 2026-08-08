// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {LzCodec} from "./LzCodec.sol";

/// @notice The LayerZero transceiver on the home chain. One instance, owned by the crossecute
///         msig, shared by every user's transmitter.
///
/// @dev Does NOT inherit `LzTransmitter`. A transceiver is shared, msig-owned
///      infrastructure; a transmitter is per-user and deployed by `TransmitterFactory`.
///      Merging them would give one contract two different owners (the msig for the
///      transceiver half, the user for the transmitter half), which is why `owner` and
///      `onlyOwner` collide outright when you try.
///
/// @dev THE EID NEVER APPEARS IN THIS CONTRACT'S STATE. `HubTransceiverBase._route`
///      returns it from the registry as opaque bytes and `LzCodec` decodes it at the
///      point of use, so adding a destination is a registry write rather than a
///      transceiver upgrade.
contract LzHubTransceiver is HubTransceiverBase, OwnableUpgradeable {
    /// @dev NO RECEIVER IMPLEMENTATION, because a hub never makes a receiver. The
    ///      manufacturing half lives on the spoke; see `TransceiverBase`.
    function initialize(address owner_, address transmitterImplementation_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransceiverBase_init();
        __HubTransceiverBase_init(transmitterImplementation_);
    }

    /// @notice Where the transceiver's `_checkAdmin` requirement is satisfied.
    /// @dev THIS IS THE SEAM. Today the authority is `OwnableUpgradeable`, declared right
    ///      here rather than in the base. When this contract becomes an actual OApp the
    ///      inheritance list gains `OAppUpgradeable` and this body becomes `_checkOwner()`
    ///      against OApp's own `Ownable`, one line, and nothing in `TransceiverBase`
    ///      changes, because it never had an opinion about ownership to begin with.
    function _checkAdmin() internal view override {
        _checkOwner();
    }

    /// @notice Tie a LayerZero endpoint id to a chainKey. WRITE-ONCE, like the untyped
    ///         `setRoute` it wraps.
    ///
    /// @dev THE TYPED SETTER IS WHY THE BASE STORES `bytes`. The base has no business
    ///      knowing what an eid is (a Hyperlane binding would wrap the same slot as a
    ///      `uint32 domain`, a Wormhole one as a `uint16`), so the shape is stated here,
    ///      at the one layer that speaks LayerZero, and `abi.encode` keeps it fixed-width
    ///      so a mistyped value fails in `decodeEid` rather than silently reinterpreting.
    function setEid(bytes32 chainKey, uint32 eid) external {
        setRoute(chainKey, LzCodec.encodeEid(eid));
    }

    /// @notice The LayerZero endpoint id to send to for a destination chainKey.
    function eidFor(bytes32 chainKey) public view returns (uint32) {
        return LzCodec.decodeEid(routeTo(chainKey));
    }

    /// @notice The chain a LayerZero source eid refers to, on the inbound path.
    function chainKeyForEid(uint32 srcEid) public view returns (bytes32) {
        return _chainKeyOf(LzCodec.encodeEid(srcEid));
    }
}
