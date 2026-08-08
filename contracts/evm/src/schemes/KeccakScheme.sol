// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICommitmentScheme} from "src/registry/ICommitmentScheme.sol";

/// @title KeccakScheme
/// @notice The primitive every EVM destination uses, plus Solana, Aptos, Sui, NEAR, and
///         Cosmos. `Scheme.Keccak256` in the enum the frozen transmitters carry.
///
/// @dev IT EXISTS TO BE THE CONTROL. An EVM chain never needs the plugin path: its
///      receiver enforces with the keccak fold compiled into `ReceiverBase`. Registering
///      this one anyway means `ChainRegistry.commitmentFor` can be checked against
///      `Commitment.hashCalls` for the same inputs, which is the assertion that the
///      plugin seam reproduces the frozen path rather than merely resembling it.
contract KeccakScheme is ICommitmentScheme {
    function hash(bytes calldata data) external pure override returns (bytes32) {
        return keccak256(data);
    }
}
