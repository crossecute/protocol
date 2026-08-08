// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICommitmentScheme} from "src/registry/ICommitmentScheme.sol";

/// @title Sha256Scheme
/// @notice TON's primitive. `Scheme.Sha256` in the enum the frozen transmitters carry.
/// @dev `sha256` is an EVM builtin (precompile 0x02, wrapped by the compiler), so this
///      stays computable on both sides — which is why TON was expressible from the start
///      while Starknet was not.
contract Sha256Scheme is ICommitmentScheme {
    function hash(bytes calldata data) external pure override returns (bytes32) {
        return sha256(data);
    }
}
