// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ICommitmentScheme
/// @notice The registry's per-chain commitment primitive, for PREVIEW ONLY.
///
/// @dev IT IS THE PRIMITIVE, NOT THE FOLD, AND THAT IS THE WHOLE DESIGN. `Commitment.sol`
///      states that the fold is fixed and only the primitive varies; this interface makes
///      that structural rather than conventional. The registry performs the fold and calls
///      in here for each hash, so a plugin cannot change the SHAPE of a commitment however
///      wrong or hostile it is: the worst it can do is produce a digest the destination
///      refuses. A plugin that returned a whole commitment could quietly fold differently
///      and nothing would notice until a live message.
///
/// @dev NOTHING ON THE EXECUTION PATH READS THIS. A receiver enforces its commitment with
///      the keccak256 fold compiled into `ReceiverBase`, which is frozen with the account
///      and can never consult a mutable lookup. This exists so a signer can ask, on-chain,
///      "what am I approving" for a destination whose hash their own transmitter was
///      compiled too early to know about. Advisory here, enforced there: that split is
///      what keeps a swappable plugin from being a forgery surface.
///
/// @dev `view` RATHER THAN `pure`, FOR THE SAME ONE REASON THE LIBRARY IS. Blake2b-256
///      reaches the EIP-152 precompile through `staticcall`, which Solidity forbids inside
///      `pure`. It costs nothing where it matters: this is read through `eth_call`.
interface ICommitmentScheme {
    /// @notice The destination's hash of `data`.
    /// @dev MUST be the exact primitive the destination's own receiver applies. A
    ///      mismatch is not a safety hole (the destination simply never matches the
    ///      commitment), but it wedges that receiver's FIFO queue until a `cancel`
    ///      crosses, so it is verified against `test/vectors/` rather than assumed.
    function hash(bytes calldata data) external view returns (bytes32);
}

/// @title SchemeFold
/// @notice The commitment fold, over a plugin's primitive.
///
/// @dev THIS IS THE SECOND DEFINITION OF ONE FOLD, AND IT IS DELIBERATE RATHER THAN AN
///      OVERSIGHT. `Commitment.hashCalls` is the first, and the two must agree byte for
///      byte. They cannot be merged: `Commitment` lives in `messaging`, which imports
///      `registry`, so a registry contract importing `Commitment` would close a cycle in
///      a dependency graph the README states runs one way. Solidity offers no third
///      option either, because the only difference between the two bodies is whether the
///      primitive is an enum arm or an external call, and an internal function pointer
///      cannot close over the value that decides.
///
///      So it is written out once here, kept adjacent to the interface it folds with, and
///      pinned equal to the library by `test/CommitmentSchemePlugin.t.sol` for every
///      primitive the enum carries. If that test ever goes, this comment is the warning.
///
/// @dev IT LIVES HERE RATHER THAN IN `ChainRegistry` because a registry stores bindings.
///      Defining a hash is not that, and a thousand-line contract is the wrong place to
///      hide four lines everything else in the protocol has to match.
library SchemeFold {
    /// @notice The commitment `scheme`'s chain will require over `elements`.
    ///
    /// @dev THE CHAINKEY IS THE SEED, and the plugin never learns it as a chainKey, only
    ///      as bytes to hash. Cross-chain replay protection is therefore not a plugin's
    ///      to weaken: it cannot bind a commitment to a chain other than the one asked
    ///      for, however wrong its primitive is.
    ///
    /// @dev AN EMPTY ARRAY HASHES TO THE SEED ALONE, matching `Commitment`. Non-zero, and
    ///      therefore a valid commitment.
    function hashCalls(
        ICommitmentScheme scheme,
        bytes32 destinationChainKey,
        bytes[] memory elements
    ) internal view returns (bytes32 hashed) {
        hashed = scheme.hash(abi.encode(destinationChainKey));
        uint256 len = elements.length;
        for (uint256 i = 0; i < len; i++) {
            hashed = scheme.hash(abi.encodePacked(hashed, scheme.hash(elements[i])));
        }
    }
}
