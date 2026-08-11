// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice The transceiver on the home chain. One instance, owned by the crossecute msig,
///         shared by every user's transmitter.
///
/// @dev IT CARRIES NO PROVIDER VOCABULARY AT ALL, AND THAT IS WHAT ERC-7786 BOUGHT. The
///      route table used to hold a LayerZero endpoint id behind a typed `setEid`, because
///      every provider names chains its own way and the base had no business knowing which.
///      A gateway takes a recipient that NAMES ITS OWN CHAIN, so there is nothing left to
///      translate and `LzCodec` is gone. A native SDK binding would bring one back, since
///      `_lzSend` still takes a `uint32`.
///
/// @dev Does NOT inherit a transmitter. A transceiver is shared, msig-owned infrastructure
///      and a transmitter is per-user; merging them would give one contract two owners,
///      which is why `owner` and `onlyOwner` collide when you try.
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
    function _checkAdmin() internal view override {
        _checkOwner();
    }
}
