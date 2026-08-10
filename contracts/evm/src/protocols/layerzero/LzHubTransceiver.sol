// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice The transceiver on the home chain. One instance, owned by the crossecute msig,
///         shared by every user's transmitter.
///
/// @dev IT CARRIES NO PROVIDER VOCABULARY AT ALL NOW, and that is what ERC-7786 bought.
///      The route table used to hold a LayerZero endpoint id, wrapped in a typed `setEid`
///      over the base's untyped `setRoute`, because every provider names chains its own
///      way and the base had no business knowing which. A gateway takes a recipient that
///      NAMES ITS OWN CHAIN, so there is nothing left to translate: the route slot holds
///      the chain's ERC-7930 identifier, `setRoute` is already typed for that, and
///      `LzCodec` is gone.
///
/// @dev Does NOT inherit a transmitter. A transceiver is shared, msig-owned
///      infrastructure; a transmitter is per-user. Merging them would give one contract
///      two different owners, which is why `owner` and `onlyOwner` collide when you try.
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
