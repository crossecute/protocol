// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ChainType} from "src/addressing/ChainType.sol";

/// @title Erc7930
/// @notice Encoding, strict parsing, and key derivation for ERC-7930 Interoperable
///         Addresses: the binary envelope that binds a chain identity to an address.
///
/// @dev Layout (all lengths in bytes):
///        ┌─────────┬───────────┬──────────────────────┬────────────────┬───────────────┬─────────┐
///        │ Version │ ChainType │ ChainReferenceLength │ ChainReference │ AddressLength │ Address │
///        │    2    │     2     │          1           │    variable    │       1       │variable │
///        └─────────┴───────────┴──────────────────────┴────────────────┴───────────────┴─────────┘
///
///      This solves the arbitrary-length problem structurally: a NEAR named account,
///      a 57-byte Cardano address, a TON workchain+account_id, and a 20-byte EVM
///      address are all the same shape. The envelope carries the length, so no bespoke
///      Form/kind discriminant is needed.
///
/// @dev Canonicity is the whole game here. ERC-7930's own Security Considerations warn
///      implementers using these as mapping keys to check each CAIP-350 profile for
///      non-canonical encodings. Two byte strings that mean the same address but differ
///      by one byte hash to different keys: a silent split-brain in any registry.
///      This library therefore rejects non-minimal chain references (`0x0001` for
///      chain 1 is invalid; `0x01` is the only valid form) and rejects trailing bytes.
///      Never accept a raw interop blob from a remote caller without `parseStrict`.
///
/// @dev The rules are per profile, and a chain type with no rule is accepted. `chainType`
///      is read as an opaque `uint16` and never checked against `ChainType.sol`, so an
///      unallocated value parses and registers. It simply arrives with no canonicity
///      condition attached: both `0x00cafe` and `0xcafe` would pass as chain references
///      for the same chain and hash to two different keys.
///
///      **Adding a `ChainType` constant does not close that.** The rule has to be written
///      into `parseStrict` below, beside the eip155 and starknet cases. It is the one step of
///      onboarding a chain that nothing here will remind you about: see "Adding a chain type"
///      in the README. `test/UnknownChainType.t.sol` pins the current behaviour.
library Erc7930 {
    uint16 internal constant VERSION_1 = 0x0001;

    /* --------------------------- CAIP-350 chain types --------------------------- */
    // Aliases into `ChainType`, which is the one allocation table for the repo.
    uint16 internal constant CT_EIP155 = ChainType.EIP155;
    uint16 internal constant CT_STARKNET = ChainType.STARKNET;

    /// @dev Starknet addresses are 32-byte field elements, zero-padded. Unlike eip155,
    ///      leading zeros are required, so minimality must not be enforced on them.
    uint256 internal constant STARKNET_ADDRESS_BYTES = 32;

    error BadVersion();
    error BadLength();
    error NonMinimalChainRef();
    error TrailingBytes();
    error EmptyEnvelope();
    error NotEvm();
    error BadStarknetAddressLength();

    struct Interop {
        uint16 version;
        uint16 chainType;
        bytes chainRef;
        bytes addr;
    }

    /* ================================ encoding ================================ */

    /// @notice Build an interoperable address from parts.
    /// @dev `chainRef` must already be minimally encoded per its CAIP-350 profile.
    ///      Use `encodeEvm` for eip155 rather than encoding the chain id by hand.
    function encode(uint16 chainType, bytes memory chainRef, bytes memory addr) internal pure returns (bytes memory) {
        if (chainRef.length > 255 || addr.length > 255) revert BadLength();
        if (chainRef.length == 0 && addr.length == 0) revert EmptyEnvelope();
        // forge-lint: disable-next-line(encode-packed-collision,unsafe-typecast) lengths checked <= 255 above, and each is prefixed
        return abi.encodePacked(VERSION_1, chainType, uint8(chainRef.length), chainRef, uint8(addr.length), addr);
    }

    /// @notice eip155 interoperable address. ChainReference is the chain id as a
    ///         Minimal big-endian integer: chain 1 -> 0x01, Base (8453) -> 0x2105.
    function encodeEvm(uint256 chainId, address a) internal pure returns (bytes memory) {
        return encode(CT_EIP155, minimalBigEndian(chainId), abi.encodePacked(a));
    }

    /// @notice A Chain Identifier: an interop address with a zero-length Address.
    ///         Identifies a chain rather than an account on it.
    function encodeChainId(uint16 chainType, bytes memory chainRef) internal pure returns (bytes memory) {
        return encode(chainType, chainRef, "");
    }

    function encodeEvmChain(uint256 chainId) internal pure returns (bytes memory) {
        return encodeChainId(CT_EIP155, minimalBigEndian(chainId));
    }

    /* ================================ parsing ================================= */

    /// @notice Parse and fully validate. Reverts on anything non-canonical.
    /// @dev Checks: version, declared lengths against actual, no trailing bytes,
    ///      not both-empty, and minimal chain-reference encoding for eip155.
    function parseStrict(bytes memory raw) internal pure returns (Interop memory io) {
        if (raw.length < 6) revert BadLength();

        io.version = (uint16(uint8(raw[0])) << 8) | uint16(uint8(raw[1]));
        if (io.version != VERSION_1) revert BadVersion();
        io.chainType = (uint16(uint8(raw[2])) << 8) | uint16(uint8(raw[3]));

        uint256 crLen = uint8(raw[4]);
        if (raw.length < 5 + crLen + 1) revert BadLength();
        io.chainRef = _slice(raw, 5, crLen);

        uint256 alPos = 5 + crLen;
        uint256 aLen = uint8(raw[alPos]);
        if (raw.length != alPos + 1 + aLen) revert TrailingBytes();
        io.addr = _slice(raw, alPos + 1, aLen);

        if (crLen == 0 && aLen == 0) revert EmptyEnvelope();

        // eip155: chain reference is a minimal big-endian integer. A leading zero byte
        // means two distinct encodings of the same chain, and therefore two keys.
        if (io.chainType == CT_EIP155 && crLen > 0) {
            if (io.chainRef[0] == 0x00) revert NonMinimalChainRef();
            if (crLen > 32) revert BadLength();
        }

        // starknet: the opposite rule. Addresses are fixed-width 32-byte field
        // elements with leading zeros, so width is the canonicity condition here. Chain
        // references are the UTF-8 chain ID string ("SN_MAIN"), not an integer, so the
        // eip155 minimality rule would reject every valid one.
        // The value-range check (< ADDR_BOUND) is not a structural property and lives
        // in StarknetDerive, wired in as a per-chain validator.
        if (io.chainType == CT_STARKNET && aLen != 0) {
            if (aLen != STARKNET_ADDRESS_BYTES) revert BadStarknetAddressLength();
        }
    }

    /// @notice The Chain Identifier form of an interop address: same chain, no account.
    /// @dev This is what makes `chainKey` stable across every address on a chain.
    function toChainIdentifier(bytes memory raw) internal pure returns (bytes memory) {
        Interop memory io = parseStrict(raw);
        return encodeChainId(io.chainType, io.chainRef);
    }

    /* ================================== keys =================================== */

    /// @notice Grouping key for "which chain is this on", independent of the account.
    function chainKey(bytes memory raw) internal pure returns (bytes32) {
        return keccak256(toChainIdentifier(raw));
    }

    /* ================================ helpers ================================== */

    /// @notice True if this envelope names an EVM chain with a 20-byte address, i.e.
    ///         the registry can resolve it locally with CREATE2 instead of a round trip.
    function isEvmAccount(Interop memory io) internal pure returns (bool) {
        return io.chainType == CT_EIP155 && io.addr.length == 20 && io.chainRef.length > 0;
    }

    function toAddress(Interop memory io) internal pure returns (address a) {
        if (!isEvmAccount(io)) revert NotEvm();
        bytes memory b = io.addr;
        assembly {
            a := shr(96, mload(add(b, 32)))
        }
    }

    /// @notice Minimal big-endian encoding of an integer: the eip155 chain-reference
    ///         rule: chain 1 is `0x01`, Base (8453) is `0x2105`, and a leading zero byte
    ///         is invalid.
    ///
    /// @dev It lives here because it is an encoding rule, not a derivation. Putting it in
    ///      the address-derivation library would make `addressing` import `derivation`
    ///      while every deriver imports `addressing` back: a cycle between the two
    ///      folders over one integer helper. Canonicity is this library's
    ///      responsibility, so the rule that decides it belongs next to `parseStrict`,
    ///      which is what rejects violations of it.
    ///
    /// @dev `AddressDerive` uses it too, for the RLP nonce in a CREATE derivation. That
    ///      is a different rule reached by the same encoding, and it had its own private
    ///      copy of this body until the two were merged here. `derivation` imports
    ///      `addressing`, which is the direction this comment always said was open.
    function minimalBigEndian(uint256 x) internal pure returns (bytes memory out) {
        uint256 len;
        uint256 t = x;
        while (t != 0) {
            ++len;
            t >>= 8;
        }
        out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast) one byte of x
            out[len - 1 - i] = bytes1(uint8(x >> (8 * i)));
        }
    }

    function _slice(bytes memory src, uint256 start, uint256 len) private pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = src[start + i];
        }
    }
}
