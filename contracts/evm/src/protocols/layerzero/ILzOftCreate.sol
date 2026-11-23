// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Creates a LayerZero OFT conduit on its home chain.
interface ILzOftCreate {
    /// @notice A destination record hashed into the conduit's OFT destination root.
    struct OftLeaf {
        bytes32 chainKey;
        uint32 eid;
        address oft;
    }

    function createTransmitter(bytes32 salt, address homeOft, OftLeaf[] calldata leaves)
        external
        returns (address conduit);
}
