// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice What a `layerzero-oft` account reads from the factory that created it, beyond the
///         views `TransmitterBase` reads from any transceiver.
interface ILzOftFactory {
    /// @notice Where `account`'s bootstrap to `chainKey` goes, the home eid and root bound into
    ///         the account's address, and the proof of that destination in the root.
    /// @dev Reverts for a chain the account was not created with.
    function bootstrapRoute(address account, bytes32 chainKey)
        external
        view
        returns (uint32 eid, address dstOft, uint32 homeEid, bytes32 destRoot, bytes32[] memory proof);
}
