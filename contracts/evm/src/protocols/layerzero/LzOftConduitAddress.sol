// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {OrderedMerkle} from "src/messaging/OrderedMerkle.sol";
import {ILzOftConduitFactory} from "src/protocols/layerzero/ILzOftConduitFactory.sol";

/// @notice What a `layerzero-oft` conduit's address commits to, computed offline: each
///         destination's leaf, the destination root, the CREATE2 salt and the address.
///         `LzOftConduitFactory` uses the same functions.
/// @dev Checks only what needs no chain state. The factory also requires each destination to
///      be a peer of the home OFT, and a destination's eid is checked only by its bootstrap.
library LzOftConduitAddress {
    /// @notice A destination's leaf in a conduit's `destRoot`.
    function leafHash(ILzOftConduitFactory.Destination memory d) internal pure returns (bytes32) {
        return OrderedMerkle.leafHash(abi.encode(d.chainKey, d.eid, d.oft));
    }

    /// @notice Reverts as `createTransmitter` does for a list it refuses before reading peers.
    function requireDestinations(
        ILzOftConduitFactory.Destination[] memory destinations,
        bytes32 homeChainKey,
        uint32 homeEid
    ) internal pure {
        if (destinations.length == 0) revert ILzOftConduitFactory.NoDestinations();
        for (uint256 i; i < destinations.length; ++i) {
            ILzOftConduitFactory.Destination memory d = destinations[i];
            if (i != 0 && d.chainKey <= destinations[i - 1].chainKey) {
                revert ILzOftConduitFactory.DestinationsNotSorted(i);
            }
            if (d.chainKey == homeChainKey || d.eid == 0 || d.eid == homeEid || d.oft == address(0)) {
                revert ILzOftConduitFactory.BadDestination(i);
            }
        }
    }

    /// @notice Each destination's leaf, in list order: the leaves of `destRoot`.
    function leafHashes(ILzOftConduitFactory.Destination[] memory destinations)
        internal
        pure
        returns (bytes32[] memory hashes)
    {
        hashes = new bytes32[](destinations.length);
        for (uint256 i; i < destinations.length; ++i) {
            hashes[i] = leafHash(destinations[i]);
        }
    }

    /// @notice The `destRoot` the factory binds into a conduit created on `homeChainKey` through
    ///         an OFT whose endpoint is `homeEid`.
    function destRoot(ILzOftConduitFactory.Destination[] memory destinations, bytes32 homeChainKey, uint32 homeEid)
        internal
        pure
        returns (bytes32)
    {
        requireDestinations(destinations, homeChainKey, homeEid);
        return OrderedMerkle.root(leafHashes(destinations));
    }

    function conduitSalt(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        uint32 homeEid,
        address homeOft,
        bytes32 root
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt, homeChainKey, homeEid, homeOft, root));
    }

    /// @notice The conduit `factory` creates for these inputs, at the same address on every chain.
    /// @param proxyInitCodeHash The factory's `PROXY_INIT_CODE_HASH()`.
    function predictConduit(
        address factory,
        bytes32 proxyInitCodeHash,
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        uint32 homeEid,
        address homeOft,
        bytes32 root
    ) internal pure returns (address) {
        return Create2.computeAddress(
            conduitSalt(owner, salt, homeChainKey, homeEid, homeOft, root), proxyInitCodeHash, factory
        );
    }
}
