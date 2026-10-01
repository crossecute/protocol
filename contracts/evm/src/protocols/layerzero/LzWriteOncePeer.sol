// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OAppCoreUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";

/// @notice OApp's `setPeer`, made write-once per eid for the contracts that have an owner: the
///         hub and the transmitter. LayerZero delivers to the peer, not to the recipient's
///         address, so the peer gets the same guarantee as the route and counterpart it
///         duplicates. Re-declaring the same peer is a no-op.
abstract contract LzWriteOncePeer is OAppCoreUpgradeable {
    error ZeroPeer(uint32 eid);
    error PeerAlreadySet(uint32 eid);

    function setPeer(uint32 eid, bytes32 peer) public virtual override onlyOwner {
        if (peer == bytes32(0)) revert ZeroPeer(eid);
        bytes32 existing = peers(eid);
        if (existing != bytes32(0)) {
            if (existing != peer) revert PeerAlreadySet(eid);
            return;
        }
        super.setPeer(eid, peer);
    }
}
