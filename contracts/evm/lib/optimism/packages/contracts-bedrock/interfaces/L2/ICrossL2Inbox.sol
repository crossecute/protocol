// SPDX-License-Identifier: MIT

// Vendored, unmodified, from ethereum-optimism/optimism @ dfe4f947ca48f872ce207c3e1e36a9256beaa044
// (packages/contracts-bedrock/interfaces/L2/ICrossL2Inbox.sol).
// MIT, like the rest of contracts-bedrock. Imports only ICrossL2Inbox, vendored
// beside it. See docs/provider-research.md#7-op-stack-as-a-native-binding.

pragma solidity ^0.8.0;

/// @notice Identifier of a cross chain message.

struct Identifier {
    address origin;
    uint256 blockNumber;
    uint256 logIndex;
    uint256 timestamp;
    uint256 chainId;
}

interface ICrossL2Inbox {
    error CrossL2Inbox_NoExecutingDeposits();
    error NotInAccessList();
    error BlockNumberTooHigh();
    error TimestampTooHigh();
    error LogIndexTooHigh();

    event ExecutingMessage(bytes32 indexed msgHash, Identifier id);

    function version() external view returns (string memory);

    function validateMessage(Identifier calldata _id, bytes32 _msgHash) external;

    function calculateChecksum(Identifier memory _id, bytes32 _msgHash) external pure returns (bytes32 checksum_);
}
