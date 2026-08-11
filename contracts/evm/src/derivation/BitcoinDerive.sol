// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title BitcoinDerive
/// @notice Bitcoin script and witness-program hashing, for `bip122` references.
///
/// @dev SPLIT OUT OF `AddressDerive` TO KEEP `ripemd160` OFF ERAVM, and that is a compile
///      constraint rather than a taste one. zkSync's compiler rejects the `ripemd160`
///      precompile outright, and it rejects the whole compilation unit rather than the
///      unreachable function: a zkSync spoke needs `AddressDerive.zksyncCreate2` and would
///      otherwise drag `hash160` in with it and fail to build. Nothing else separated these,
///      since both halves are "hash bytes with a precompile".
///
/// @dev NOTHING ON A SPOKE CALLS THIS. Bitcoin has no executor and no receiver: `bip122`
///      appears in the registry as a reference that can be validated and addressed, never
///      as a destination a payload runs on. Its only caller is `VmDeriver`, which is
///      home-chain machinery, so this file never reaches a chain that cannot compile it.
library BitcoinDerive {
    /// @notice HASH160 = ripemd160(sha256(x)). P2PKH and P2WPKH witness programs.
    function hash160(bytes memory data) internal pure returns (bytes20) {
        return ripemd160(abi.encodePacked(sha256(data)));
    }

    /// @notice P2WSH witness program = sha256(witnessScript).
    function p2wshProgram(bytes memory witnessScript) internal pure returns (bytes32) {
        return sha256(witnessScript);
    }

    /// @notice P2SH script hash = hash160(redeemScript).
    function p2shScriptHash(bytes memory redeemScript) internal pure returns (bytes20) {
        return hash160(redeemScript);
    }
}
