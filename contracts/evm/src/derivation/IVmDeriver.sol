// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Uniform address derivation across every VM the protocol targets.
///
/// @dev The normalization problem. Every VM's derivation takes different inputs: CREATE2
///      wants (deployer, salt, initCodeHash), a Solana PDA wants (seeds[], bump,
///      programId), CosmWasm wants (checksum, creator, salt, initMsg). There is no
///      argument list that fits all of them, so the parameters stay opaque: the caller
///      passes an ABI-encoded blob and the deriver decodes the shape its scheme requires.
///
///      What is uniform is the two ends. Every implementation takes a canonical ERC-7930
///      chain identifier plus a params blob, and returns a canonical ERC-7930 account
///      envelope for the same chain. The registry can therefore store the result without
///      knowing which VM produced it.
///
/// @dev Kept apart from `VmDeriver` so that `ChainRegistry`, which every chain deploys, does
///      not import `BitcoinDerive`: zksolc rejects any unit containing `ripemd160`.
///
/// @dev Must be `view`, not `pure`. Sui's BLAKE2b-256 goes through precompile 0x09, which
///      is a `staticcall`. One non-pure member forces the whole interface to `view`.
interface IVmDeriver {
    /// @param chainIdentifier Canonical ERC-7930 chain identifier (zero-length address).
    /// @param params          `abi.encode(Scheme, bytes)`: see `VmDeriver.Scheme`.
    /// @return interop        Canonical ERC-7930 account envelope on that same chain.
    function deriveAddress(bytes calldata chainIdentifier, bytes calldata params)
        external
        view
        returns (bytes memory interop);

    /// @notice Whether this deriver can serve `scheme` on `chainType`.
    /// @dev Lets the registry reject a misconfiguration at wiring time rather than at
    ///      the first resolve.
    function supportsScheme(uint16 chainType, uint8 scheme) external pure returns (bool);
}
