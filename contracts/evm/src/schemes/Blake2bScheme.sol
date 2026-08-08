// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Blake2b256} from "src/derivation/Blake2b256.sol";
import {ICommitmentScheme} from "src/registry/ICommitmentScheme.sol";

/// @title Blake2bScheme
/// @notice Cardano's primitive. `Scheme.Blake2b256Scheme` in the enum the frozen
///         transmitters carry.
/// @dev THE ONE THAT COSTS `pure`. `Blake2b256` reaches the EIP-152 precompile at 0x09
///      through `staticcall`, which Solidity forbids inside `pure` — so this member is
///      why `ICommitmentScheme.hash` is `view`, exactly as it is why the library's
///      scheme-parameterized overloads are.
contract Blake2bScheme is ICommitmentScheme {
    function hash(bytes calldata data) external view override returns (bytes32) {
        return Blake2b256.hash(data);
    }
}
