// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice What a `layerzero-oft` conduit reads from the factory that created it, beyond the
///         views `TransmitterBase` reads from any transceiver.
interface ILzOftConduitFactory {
    /// @notice The eid and OFT `conduit` reaches `chainKey` through, as it was created with.
    /// @dev Reverts for a chain the conduit was not created with.
    function destinationOf(address conduit, bytes32 chainKey) external view returns (uint32 eid, address oft);
}

/// @notice Bootstrap transport for a signed OFT conduit; the conduit remains the OFT sender.
interface ILzOftSignedConduitFactory is ILzOftConduitFactory {
    /// @notice Encode the calling conduit's signed bootstrap and its destination factory route.
    /// @dev Quote and send use identical bytes without making the factory the composeFrom.
    function signedConduitBootstrap(bytes calldata route, bytes calldata body)
        external
        view
        returns (bytes memory recipient, bytes memory message);
}

/// @notice Address prediction and committed destination routes from a LayerZero OFT factory.
interface ILzOftConduitFactoryView is ILzOftConduitFactory {
    /// @notice The deployed factory's Proxy initcode hash for offline address prediction.
    function PROXY_INIT_CODE_HASH() external view returns (bytes32);

    /// @notice Predict the conduit address committed to these creation inputs.
    function predictConduit(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        uint32 homeEid,
        address homeOft,
        bytes32 destRoot
    ) external view returns (address);

    /// @notice The destination and proof carried by a bootstrap from `conduit` to `chainKey`.
    /// @dev Reverts if the conduit was not created with this chain.
    function bootstrapRoute(address conduit, bytes32 chainKey)
        external
        view
        returns (uint32 eid, address dstOft, uint32 homeEid, bytes32 destRoot, bytes32[] memory proof);
}
