// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OAppCoreUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";

/// @notice Sets a peer during an initializer: a receiver's one peer, and a transceiver's peer
///         for the governor's home.
/// @dev OApp's `setPeer` is `onlyOwner`, and neither has an owner able to call it yet (a receiver
///      never does; a transceiver's is created by the very bootstrap the peer admits), so the
///      initializer writes the peer to OApp storage directly.
abstract contract LzHomePeer is OAppCoreUpgradeable {
    /// @dev Zero is LayerZero's unset eid, so a peer there would admit nothing.
    error ZeroHomeEid();

    function _initHomePeer(uint32 eid, address peer) internal onlyInitializing {
        if (eid == 0) revert ZeroHomeEid();
        bytes32 peer32 = bytes32(uint256(uint160(peer)));
        _getOAppCoreStorage().peers[eid] = peer32;
        emit PeerSet(eid, peer32);
    }
}
