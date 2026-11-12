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
    /// @dev Quote and retry use identical bytes without making the factory the composeFrom.
    function signedConduitBootstrap(bytes32 chainKey, bytes calldata body)
        external
        view
        returns (bytes memory recipient, bytes memory message);
}
