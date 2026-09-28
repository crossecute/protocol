// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ICommitmentScheme
/// @notice A chain's commitment hash primitive, for previewing a commitment on this chain.
///
/// @dev The plugin supplies the primitive and `SchemeFold` performs the fold, so a wrong or
///      hostile plugin can yield a digest the destination refuses but cannot change a
///      commitment's shape. Nothing on the execution path reads it: a receiver enforces the
///      fold compiled into `ReceiverBase`.
///
/// @dev `view`, not `pure`: Blake2b-256 calls the EIP-152 precompile through `staticcall`.
interface ICommitmentScheme {
    /// @notice The destination's hash of `data`.
    /// @dev Must be the primitive the destination's receiver applies, checked against a test
    ///      corpus. A mismatch leaves an approval outstanding until a `cancel` crosses.
    function hash(bytes calldata data) external view returns (bytes32);
}

/// @title SchemeFold
/// @notice The commitment fold over a plugin's primitive.
/// @dev A second copy of `Commitment.hashCalls`'s fold. They cannot share code: `messaging`
///      imports `registry`, and the primitive is an enum arm in one and an external call in
///      the other. `test/CommitmentSchemePlugin.t.sol` pins the two equal for every enum
///      primitive.
library SchemeFold {
    /// @notice The commitment `scheme`'s chain will require over `elements`.
    /// @dev Seeded with the chainKey, so no plugin can bind a commitment to another chain. An
    ///      empty array hashes to the seed alone, as in `Commitment`.
    function hashCalls(ICommitmentScheme scheme, bytes32 destinationChainKey, bytes[] memory elements)
        internal
        view
        returns (bytes32 hashed)
    {
        hashed = scheme.hash(abi.encode(destinationChainKey));
        uint256 len = elements.length;
        for (uint256 i = 0; i < len; i++) {
            hashed = scheme.hash(abi.encodePacked(hashed, scheme.hash(elements[i])));
        }
    }
}
