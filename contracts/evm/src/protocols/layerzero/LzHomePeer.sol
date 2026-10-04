// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OAppCoreUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";

/// @notice Sets the one peer a LayerZero receiver trusts, during its initializer.
/// @dev OApp's `setPeer` is `onlyOwner`, and a receiver initializes no owner, so the
///      initializer writes the peer to OApp storage directly. It is the only chance to set it.
abstract contract LzHomePeer is OAppCoreUpgradeable {
    /// @dev Zero is LayerZero's unset eid, so a receiver homed there would accept nothing.
    error ZeroHomeEid();

    function _initHomePeer(uint32 eid, address peer) internal onlyInitializing {
        if (eid == 0) revert ZeroHomeEid();
        bytes32 peer32 = bytes32(uint256(uint160(peer)));
        _getOAppCoreStorage().peers[eid] = peer32;
        emit PeerSet(eid, peer32);
    }
}
