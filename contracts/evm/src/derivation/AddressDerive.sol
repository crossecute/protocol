// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title AddressDerive
/// @notice Deterministic address derivation across EVM and non-EVM chains, computed
///         on-chain inside an Ethereum transaction. Pure where possible, no chain state.
///
/// @dev Formerly ForeignCreate2. EVM derivations are now first-class rather than a
///      test-only comparison, because on an EVM destination the registry can resolve
///      locally and skip the round trip entirely.
///
/// @dev SCOPE. Everything here bottoms out in `keccak256` (native), `sha256` (0x02),
///      or `ripemd160` (0x03). Sui lives in SuiDerive.sol because BLAKE2b needs the
///      0x09 precompile, which forces `view` rather than `pure`.
///      Not derivable on the EVM at any price: Aptos/Movement (SHA3-256, ~1e5 gas for
///      a hand-rolled Keccak-f), Starknet (Pedersen/Poseidon over the STARK curve),
///      Bitcoin P2TR (secp256k1 point addition). Route those through the attested path.
library AddressDerive {
    /* ====================================================================== */
    /*                                  EVM                                    */
    /* ====================================================================== */

    /// @notice EIP-1014 CREATE2. The default resolution path.
    function create2(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                deployer,
                                salt,
                                initCodeHash
                            )
                        )
                    )
                )
            );
    }

    /// @notice Nonce-based CREATE, address = keccak256(rlp([deployer, nonce]))[12:].
    /// @dev RLP has three cases for the nonce and getting them wrong is a classic bug:
    ///      0 encodes as 0x80 (empty string, NOT 0x00), 1..127 encode as themselves,
    ///      and anything larger takes a 0x80+len prefix over minimal big-endian bytes.
    function create(
        address deployer,
        uint256 nonce
    ) internal pure returns (address) {
        bytes memory rlp;
        if (nonce == 0) {
            rlp = abi.encodePacked(
                bytes1(0xd6),
                bytes1(0x94),
                deployer,
                bytes1(0x80)
            );
        } else if (nonce <= 0x7f) {
            rlp = abi.encodePacked(
                bytes1(0xd6),
                bytes1(0x94),
                deployer,
                uint8(nonce)
            );
        } else {
            bytes memory n = _minimalBE(nonce);
            rlp = abi.encodePacked(
                bytes1(uint8(0xd5 + n.length)),
                bytes1(0x94),
                deployer,
                bytes1(uint8(0x80 + n.length)),
                n
            );
        }
        return address(uint160(uint256(keccak256(rlp))));
    }

    /// @notice Creation-code hash of an EIP-1167 minimal proxy for `implementation`.
    /// @dev This is what lets Ethereum predict a RECEIVER address on a destination chain:
    ///      receivers are clones, so their address is CREATE2 over the destination
    ///      transceiver (deployer), the transmitter-derived salt, and this hash.
    ///
    ///      The 55-byte layout is EIP-1167 verbatim — 10 bytes of creation code, then the
    ///      45-byte runtime with the implementation address spliced in at byte 20:
    ///        3d602d80600a3d3981f3  363d3d373d3d3d363d73 <impl> 5af43d82803e903d91602b57fd5bf3
    ///      Verified against OpenZeppelin's `Clones.predictDeterministicAddress` in tests
    ///      rather than trusted from memory; if OZ ever changes its proxy bytecode this
    ///      constant is wrong and the test fails.
    function cloneInitCodeHash(address implementation) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
                implementation,
                hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
    }

    /// @notice Address of an EIP-1167 clone deployed with CREATE2.
    function clone2(address deployer, address implementation, bytes32 salt)
        internal
        pure
        returns (address)
    {
        return create2(deployer, salt, cloneInitCodeHash(implementation));
    }

    /// @dev Canonical CREATE3 proxy initcode: PUSH8 363d3d37363d34f0; 3d5260086018f3.
    ///      Constant across the 0xsequence, Solady, and LI.FI variants. Verified by
    ///      hashing the literal rather than copied from a header file.
    bytes32 internal constant CREATE3_PROXY_INITCODE_HASH =
        0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    /// @notice CREATE3: address depends only on (factory, salt) — never on bytecode.
    /// @dev Two stages. A fixed-initcode proxy is CREATE2-deployed, then that proxy
    ///      does a plain CREATE at nonce 1. The nonce is a hardcoded 1 from a fresh
    ///      contract, not the deployer's transaction history.
    ///
    ///      DOES NOT PORT to zkSync (both stages use different formulas) or to Tron
    ///      (CREATE derives from root tx id, so stage 2 is not a function of the proxy
    ///      address). Use only for chains sharing Ethereum's derivation.
    function create3(
        address factory,
        bytes32 salt
    ) internal pure returns (address) {
        address proxy = create2(factory, salt, CREATE3_PROXY_INITCODE_HASH);
        return create(proxy, 1);
    }

    function _minimalBE(uint256 x) private pure returns (bytes memory out) {
        uint256 len;
        uint256 t = x;
        while (t != 0) {
            ++len;
            t >>= 8;
        }
        out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[len - 1 - i] = bytes1(uint8(x >> (8 * i)));
        }
    }

    /* ====================================================================== */
    /*                             zkSync Era                                  */
    /* ====================================================================== */

    bytes32 internal constant ZKSYNC_CREATE2_PREFIX =
        keccak256("zksyncCreate2");
    bytes32 internal constant ZKSYNC_CREATE_PREFIX = keccak256("zksyncCreate");
    uint160 internal constant L1_TO_L2_ALIAS_OFFSET =
        uint160(0x1111000000000000000000000000000000001111);

    /// @param sender If an L1 *contract* triggers the deploy via Bridgehub/Mailbox, pass
    ///        the ALIASED address. EOAs are not aliased.
    /// @param bytecodeHash EraVM versioned hash — see `hashL2Bytecode`, NOT keccak(initcode).
    function zksyncCreate2(
        address sender,
        bytes32 salt,
        bytes32 bytecodeHash,
        bytes32 constructorInputHash
    ) internal pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                ZKSYNC_CREATE2_PREFIX,
                                bytes32(uint256(uint160(sender))),
                                salt,
                                bytecodeHash,
                                constructorInputHash
                            )
                        )
                    )
                )
            );
    }

    function zksyncCreate(
        address sender,
        uint256 nonce
    ) internal pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                ZKSYNC_CREATE_PREFIX,
                                bytes32(uint256(uint160(sender))),
                                bytes32(nonce)
                            )
                        )
                    )
                )
            );
    }

    /// @dev [0]=0x01 version, [1]=0x00, [2:4]=length in words, [4:32]=trailing 28 bytes
    ///      of sha256(bytecode). Invariants mirror EraVM. Requires zksolc output.
    function hashL2Bytecode(
        bytes memory bytecode
    ) internal pure returns (bytes32 h) {
        require(bytecode.length % 32 == 0, "C2L: not word-aligned");
        uint256 words = bytecode.length / 32;
        require(words < 2 ** 16, "C2L: bytecode too long");
        require(words % 2 == 1, "C2L: even word count");
        h = sha256(bytecode);
        h = h & bytes32(uint256(type(uint224).max));
        h = h | bytes32(uint256(1) << 248);
        h = h | bytes32(words << 224);
    }

    function applyL1ToL2Alias(address l1) internal pure returns (address) {
        unchecked {
            return address(uint160(l1) + L1_TO_L2_ALIAS_OFFSET);
        }
    }

    /* ====================================================================== */
    /*                                 TRON                                    */
    /* ====================================================================== */

    /// @notice Same 85-byte preimage as EIP-1014; only the domain byte differs (0x41).
    /// @dev Returns the bare 20-byte in-VM form. Prepend 0x41 + Base58Check off-chain.
    ///      initCodeHash must come from TRON-solc, not solc.
    ///      CAVEAT: TRON's docs conflict on whether high-level `new {salt:}` uses 0x41
    ///      or 0xff. Verify on Shasta before trusting this in a signed payload.
    function tronCreate2(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0x41),
                                deployer,
                                salt,
                                initCodeHash
                            )
                        )
                    )
                )
            );
    }

    /* ====================================================================== */
    /*                          Cosmos / CosmWasm                              */
    /* ====================================================================== */

    /// @dev sha256("module"), the ADR-028 domain tag.
    bytes32 internal constant COSMOS_MODULE_TAG =
        0x120970d812836f19888625587a4606a5ad23cef31c8684e601771552548fc6b9;

    /// @notice CosmWasm Instantiate2 — the CREATE2 analogue on Cosmos.
    /// @dev sha256( sha256("module") ++ key ), key = "wasm\0" ++ be64/value pairs.
    ///      The "wasm\0" prefix exists in cosmwasm-std but is ABSENT from the published
    ///      spec page. Verified against cosmwasm-std's own test vectors.
    /// @param creator CANONICAL decoded address bytes, not the bech32 string.
    function cosmosInstantiate2(
        bytes32 checksum,
        bytes memory creator,
        bytes memory salt,
        bytes memory initMsg
    ) internal pure returns (bytes32) {
        require(salt.length >= 1 && salt.length <= 64, "C2L: bad salt len");
        bytes memory key = abi.encodePacked(
            hex"7761736d00", // "wasm\0"
            uint64(32),
            checksum,
            uint64(creator.length),
            creator,
            uint64(salt.length),
            salt,
            uint64(initMsg.length),
            initMsg
        );
        return sha256(abi.encodePacked(COSMOS_MODULE_TAG, key));
    }

    /* ====================================================================== */
    /*                                Solana                                   */
    /* ====================================================================== */

    /// @notice PDA for a KNOWN bump.
    /// @dev This is NOT `find_program_address`. The canonical PDA is the first bump
    ///      counting down from 255 whose output is OFF the ed25519 curve; that check
    ///      needs Edwards decompression over GF(2^255-19) and is not implemented.
    ///      A too-high bump yields an on-curve point this function will happily return.
    ///      Bind the bump into committed inputs so signers approve it explicitly.
    function solanaCreateProgramAddress(
        bytes[] memory seeds,
        uint8 bump,
        bytes32 programId
    ) internal pure returns (bytes32) {
        require(seeds.length <= 16, "C2L: too many seeds");
        bytes memory pre;
        for (uint256 i; i < seeds.length; ++i) {
            require(seeds[i].length <= 32, "C2L: seed too long");
            pre = abi.encodePacked(pre, seeds[i]);
        }
        return
            sha256(
                abi.encodePacked(pre, bump, programId, "ProgramDerivedAddress")
            );
    }

    /// @notice SPL Associated Token Account.
    /// @dev Seed order is [owner, tokenProgram, mint] — the token program sits in the
    ///      middle, which is easy to get backwards. Verified against solders.
    function solanaAssociatedTokenAccount(
        bytes32 owner,
        bytes32 mint,
        bytes32 tokenProgram,
        bytes32 ataProgram,
        uint8 bump
    ) internal pure returns (bytes32) {
        return
            sha256(
                abi.encodePacked(
                    owner,
                    tokenProgram,
                    mint,
                    bump,
                    ataProgram,
                    "ProgramDerivedAddress"
                )
            );
    }

    /// @notice SystemProgram::createWithSeed. No bump, no off-curve requirement.
    function solanaCreateWithSeed(
        bytes32 base,
        bytes memory seed,
        bytes32 programId
    ) internal pure returns (bytes32) {
        return sha256(abi.encodePacked(base, seed, programId));
    }

    /* ====================================================================== */
    /*                                 NEAR                                    */
    /* ====================================================================== */

    /// @notice NEAR deterministic account — NEAR's CREATE2, and free here since it
    ///         uses keccak256. Render as "0s" + lowercase hex, NOT "0x".
    /// @param borshStateInit Borsh-serialized DeterministicAccountStateInit. Serialize
    ///        off-chain; do not build Borsh in Solidity.
    function nearDeterministicAccount(
        bytes memory borshStateInit
    ) internal pure returns (bytes20) {
        return bytes20(uint160(uint256(keccak256(borshStateInit))));
    }

    /// @param uncompressedPubkey64 64 bytes, WITHOUT the 0x04 SEC1 prefix.
    function nearEthImplicitAccount(
        bytes memory uncompressedPubkey64
    ) internal pure returns (bytes20) {
        require(uncompressedPubkey64.length == 64, "C2L: bad pubkey len");
        return bytes20(uint160(uint256(keccak256(uncompressedPubkey64))));
    }

    /* ====================================================================== */
    /*                                Bitcoin                                  */
    /* ====================================================================== */

    /// @notice HASH160 = ripemd160(sha256(x)). P2PKH and P2WPKH witness programs.
    function hash160(bytes memory data) internal pure returns (bytes20) {
        return ripemd160(abi.encodePacked(sha256(data)));
    }

    /// @notice P2WSH witness program = sha256(witnessScript).
    function p2wshProgram(
        bytes memory witnessScript
    ) internal pure returns (bytes32) {
        return sha256(witnessScript);
    }

    /// @notice P2SH script hash = hash160(redeemScript).
    function p2shScriptHash(
        bytes memory redeemScript
    ) internal pure returns (bytes20) {
        return hash160(redeemScript);
    }
}
