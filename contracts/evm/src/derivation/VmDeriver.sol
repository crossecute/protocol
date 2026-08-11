// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ChainType} from "src/addressing/ChainType.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {BitcoinDerive} from "src/derivation/BitcoinDerive.sol";
import {SuiDerive} from "src/derivation/SuiDerive.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice Uniform address derivation across every VM the protocol targets.
///
/// @dev THE NORMALIZATION PROBLEM. Every VM's derivation takes different inputs: CREATE2
///      wants (deployer, salt, initCodeHash), a Solana PDA wants (seeds[], bump,
///      programId), CosmWasm wants (checksum, creator, salt, initMsg). There is no
///      argument list that fits all of them, so the parameters stay OPAQUE: the caller
///      passes an ABI-encoded blob and the deriver decodes the shape its scheme requires.
///
///      What IS uniform is the two ends. Every implementation takes a canonical ERC-7930
///      chain identifier plus a params blob, and returns a canonical ERC-7930 ACCOUNT
///      envelope for the same chain. The registry can therefore store the result without
///      knowing which VM produced it.
///
/// @dev MUST BE `view`, NOT `pure`. Sui's BLAKE2b-256 goes through precompile 0x09, which
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

/// @title VmDeriver
/// @notice One standalone, stateless contract implementing every derivation the protocol
///         can perform on-chain, dispatched by (ChainType, Scheme).
///
/// @dev WHY ONE CONTRACT AND NOT ONE PER VM. These are pure functions over calldata with
///      no storage and no privileges, so there is nothing to isolate between them. A
///      single deployment means one address to audit and one address to register for
///      every chain, and the registry's `deriverOf` mapping still allows a per-chain
///      override later if a VM ever needs its own.
///
/// @dev DISPATCH IS TWO-DIMENSIONAL, and it has to be. ChainType alone is not enough:
///      Ethereum, zkSync Era, and Tron are ALL `eip155`, with three different CREATE2
///      formulas. Scheme alone is not enough either, since the same scheme must produce
///      envelopes on different chains. Every scheme is therefore checked against the
///      chain type it is legal for, in `supportsScheme`.
///
/// @dev NOT DERIVABLE HERE, BY CONSTRUCTION:
///        - Aptos / Movement: SHA3-256 is not keccak256 (padding domain 0x06 vs 0x01).
///          A hand-rolled Keccak-f[1600] is ~1e5 gas.
///        - Starknet: Pedersen/Poseidon over the STARK curve. No precompile, and the
///          point tables exceed EIP-170 outright.
///        - Bitcoin P2TR: taproot output keys need secp256k1 point addition; ecrecover
///          is not a general curve operation.
///      These revert with `UnsupportedScheme`. Route them through the registry's
///      committed or attested path: that is exactly what the provenance grades are for.
contract VmDeriver is IVmDeriver {
    /// @notice Which derivation to run. The chain type says which VM; this says which
    ///         formula within it.
    enum Scheme {
        Unset,
        /// EIP-1014. (address deployer, bytes32 salt, bytes32 initCodeHash)
        EvmCreate2,
        /// (address factory, bytes32 salt): bytecode-independent.
        EvmCreate3,
        /// Nonce-based. (address deployer, uint256 nonce)
        EvmCreate,
        /// (address sender, bytes32 salt, bytes32 bytecodeHash, bytes32 ctorInputHash)
        ZkSyncCreate2,
        /// (address sender, uint256 nonce)
        ZkSyncCreate,
        /// (address deployer, bytes32 salt, bytes32 initCodeHash)
        TronCreate2,
        /// (bytes32 checksum, bytes creator, bytes salt, bytes initMsg, uint8 addrLen)
        CosmosInstantiate2,
        /// (bytes[] seeds, uint8 bump, bytes32 programId)
        SolanaPda,
        /// (bytes32 owner, bytes32 mint, bytes32 tokenProgram, bytes32 ataProgram, uint8 bump)
        SolanaAta,
        /// (bytes32 base, bytes seed, bytes32 programId)
        SolanaCreateWithSeed,
        /// (bytes borshStateInit) -> 20 bytes, rendered "0s"+hex off-chain
        NearDeterministic,
        /// (bytes uncompressedPubkey64) -> 20 bytes
        NearEthImplicit,
        /// (bytes32 ed25519Pubkey) -> 32 bytes
        NearImplicit,
        /// (bytes pubkey) -> 20-byte HASH160 witness program
        BitcoinP2wpkh,
        /// (bytes witnessScript) -> 32-byte SHA256 witness program
        BitcoinP2wsh,
        /// (bytes redeemScript) -> 20-byte HASH160
        BitcoinP2sh,
        /// (uint8 flag, bytes pubkey)
        SuiAddress,
        /// (uint16 threshold, uint8[] flags, bytes[] pubkeys, uint8[] weights)
        SuiMultisig,
        /// (bytes32 txDigest, uint64 creationNum): verification only, see note.
        SuiObjectId,
        /// EIP-1167 clone. (address deployer, address implementation, bytes32 salt)
        /// This is how a RECEIVER address is predicted: deployer is the destination
        /// transceiver, salt is `keccak256(abi.encode(transmitter))`.
        EvmClone,
        /// EIP-1167 clone under Tron's 0x41 domain byte. Same params as EvmClone.
        TronClone
    }

    error UnsupportedScheme(uint16 chainType, uint8 scheme);

    error NotChainIdentifier();
    error BadCosmosAddressLength();

    /// @notice Creation-code hash of an EIP-1167 clone. Exposed so the same value can be
    ///         computed off-chain and pinned in a signed payload.
    function cloneInitCodeHash(address implementation) external pure returns (bytes32) {
        return AddressDerive.cloneInitCodeHash(implementation);
    }

    /* ================================ dispatch ================================= */

    /// @inheritdoc IVmDeriver
    function deriveAddress(bytes calldata chainIdentifier, bytes calldata params)
        external
        view
        override
        returns (bytes memory interop)
    {
        Erc7930.Interop memory io = Erc7930.parseStrict(chainIdentifier);
        // A chain identifier carries no account. Being handed a populated envelope means
        // the caller is confused about which end of the derivation it is on.
        if (io.addr.length != 0) revert NotChainIdentifier();

        (Scheme scheme, bytes memory inner) = abi.decode(params, (Scheme, bytes));
        if (!supportsScheme(io.chainType, uint8(scheme))) {
            revert UnsupportedScheme(io.chainType, uint8(scheme));
        }

        return Erc7930.encode(io.chainType, io.chainRef, _derive(scheme, inner));
    }

    /// @inheritdoc IVmDeriver
    /// @dev The legality table. Ethereum/zkSync/Tron all being `eip155` is why this is
    ///      keyed on the pair and not on either half alone: the registry pins the exact
    ///      scheme per chainKey, so a zkSync chainKey cannot be resolved with Ethereum's
    ///      formula just because both are eip155.
    function supportsScheme(uint16 chainType, uint8 scheme)
        public
        pure
        override
        returns (bool)
    {
        Scheme s = Scheme(scheme);

        if (chainType == ChainType.EIP155) {
            return s == Scheme.EvmCreate2 || s == Scheme.EvmCreate3 || s == Scheme.EvmCreate
                || s == Scheme.ZkSyncCreate2 || s == Scheme.ZkSyncCreate
                || s == Scheme.TronCreate2 || s == Scheme.EvmClone
                || s == Scheme.TronClone;
        }
        if (chainType == ChainType.SOLANA) {
            return s == Scheme.SolanaPda || s == Scheme.SolanaAta
                || s == Scheme.SolanaCreateWithSeed;
        }
        if (chainType == ChainType.BIP122) {
            return s == Scheme.BitcoinP2wpkh || s == Scheme.BitcoinP2wsh
                || s == Scheme.BitcoinP2sh;
        }
        if (chainType == ChainType.COSMOS) {
            return s == Scheme.CosmosInstantiate2;
        }
        if (chainType == ChainType.NEAR) {
            return s == Scheme.NearDeterministic || s == Scheme.NearEthImplicit
                || s == Scheme.NearImplicit;
        }
        if (chainType == ChainType.SUI) {
            return s == Scheme.SuiAddress || s == Scheme.SuiMultisig
                || s == Scheme.SuiObjectId;
        }
        // ChainType.APTOS and ChainType.STARKNET are deliberately absent.
        return false;
    }

    /* =============================== derivations =============================== */

    /// @dev Returns the RAW address bytes for the scheme, at the width that chain's
    ///      ERC-7930 profile expects. The caller wraps them in the envelope.
    function _derive(Scheme s, bytes memory p) private view returns (bytes memory) {
        /* ---------------------------------- EVM --------------------------------- */
        if (s == Scheme.EvmCreate2) {
            (address deployer, bytes32 salt, bytes32 initCodeHash) =
                abi.decode(p, (address, bytes32, bytes32));
            return abi.encodePacked(AddressDerive.create2(deployer, salt, initCodeHash));
        }
        if (s == Scheme.EvmCreate3) {
            (address factory, bytes32 salt) = abi.decode(p, (address, bytes32));
            return abi.encodePacked(AddressDerive.create3(factory, salt));
        }
        if (s == Scheme.EvmCreate) {
            (address deployer, uint256 nonce) = abi.decode(p, (address, uint256));
            return abi.encodePacked(AddressDerive.create(deployer, nonce));
        }

        /* -------------------------------- clones -------------------------------- */
        // NOTE ON zkSYNC: EIP-1167 has no zkSync equivalent. EraVM will only deploy
        // bytecode whose hash has been published, and a 55-byte EVM proxy is not valid
        // EraVM bytecode at all. A zkSync "clone" is a real proxy contract compiled with
        // zksolc, so it is derived with `ZkSyncCreate2` using that proxy's versioned
        // bytecode hash: no separate scheme, because it is not a clone in this sense.
        if (s == Scheme.EvmClone) {
            (address deployer, address implementation, bytes32 salt) =
                abi.decode(p, (address, address, bytes32));
            return abi.encodePacked(AddressDerive.clone2(deployer, implementation, salt));
        }
        if (s == Scheme.TronClone) {
            (address deployer, address implementation, bytes32 salt) =
                abi.decode(p, (address, address, bytes32));
            return abi.encodePacked(
                AddressDerive.tronCreate2(
                    deployer, salt, AddressDerive.cloneInitCodeHash(implementation)
                )
            );
        }

        /* -------------------------------- zkSync -------------------------------- */
        if (s == Scheme.ZkSyncCreate2) {
            (address sender, bytes32 salt, bytes32 bytecodeHash, bytes32 ctorInputHash) =
                abi.decode(p, (address, bytes32, bytes32, bytes32));
            return abi.encodePacked(
                AddressDerive.zksyncCreate2(sender, salt, bytecodeHash, ctorInputHash)
            );
        }
        if (s == Scheme.ZkSyncCreate) {
            (address sender, uint256 nonce) = abi.decode(p, (address, uint256));
            return abi.encodePacked(AddressDerive.zksyncCreate(sender, nonce));
        }

        /* --------------------------------- Tron --------------------------------- */
        if (s == Scheme.TronCreate2) {
            (address deployer, bytes32 salt, bytes32 initCodeHash) =
                abi.decode(p, (address, bytes32, bytes32));
            return abi.encodePacked(AddressDerive.tronCreate2(deployer, salt, initCodeHash));
        }

        /* -------------------------------- Cosmos -------------------------------- */
        if (s == Scheme.CosmosInstantiate2) {
            (
                bytes32 checksum,
                bytes memory creator,
                bytes memory salt,
                bytes memory initMsg,
                uint8 addrLen
            ) = abi.decode(p, (bytes32, bytes, bytes, bytes, uint8));
            bytes32 full = AddressDerive.cosmosInstantiate2(checksum, creator, salt, initMsg);
            // Canonical ADR-028 is 32 bytes. Forked wasmd chains that use 20 for
            // Ethereum-ecosystem compatibility (Injective) truncate. Only set addrLen
            // below 32 if you have confirmed the target forked ContractAddrLen:
            // getting it wrong yields a well-formed address nothing will ever occupy.
            if (addrLen == 0 || addrLen > 32) revert BadCosmosAddressLength();
            if (addrLen == 32) return abi.encodePacked(full);
            bytes memory out = new bytes(addrLen);
            for (uint256 i; i < addrLen; ++i) {
                out[i] = full[i];
            }
            return out;
        }

        /* -------------------------------- Solana -------------------------------- */
        if (s == Scheme.SolanaPda) {
            (bytes[] memory seeds, uint8 bump, bytes32 programId) =
                abi.decode(p, (bytes[], uint8, bytes32));
            return abi.encodePacked(
                AddressDerive.solanaCreateProgramAddress(seeds, bump, programId)
            );
        }
        if (s == Scheme.SolanaAta) {
            (
                bytes32 owner,
                bytes32 mint,
                bytes32 tokenProgram,
                bytes32 ataProgram,
                uint8 bump
            ) = abi.decode(p, (bytes32, bytes32, bytes32, bytes32, uint8));
            return abi.encodePacked(
                AddressDerive.solanaAssociatedTokenAccount(
                    owner, mint, tokenProgram, ataProgram, bump
                )
            );
        }
        if (s == Scheme.SolanaCreateWithSeed) {
            (bytes32 base, bytes memory seed, bytes32 programId) =
                abi.decode(p, (bytes32, bytes, bytes32));
            return abi.encodePacked(AddressDerive.solanaCreateWithSeed(base, seed, programId));
        }

        /* --------------------------------- NEAR --------------------------------- */
        if (s == Scheme.NearDeterministic) {
            bytes memory borshStateInit = abi.decode(p, (bytes));
            return abi.encodePacked(AddressDerive.nearDeterministicAccount(borshStateInit));
        }
        if (s == Scheme.NearEthImplicit) {
            bytes memory pubkey64 = abi.decode(p, (bytes));
            return abi.encodePacked(AddressDerive.nearEthImplicitAccount(pubkey64));
        }
        if (s == Scheme.NearImplicit) {
            // The ed25519 pubkey IS the account id. Identity, kept explicit so the
            // envelope width is unambiguous.
            bytes32 pubkey = abi.decode(p, (bytes32));
            return abi.encodePacked(pubkey);
        }

        /* -------------------------------- Bitcoin ------------------------------- */
        if (s == Scheme.BitcoinP2wpkh) {
            bytes memory pubkey = abi.decode(p, (bytes));
            return abi.encodePacked(BitcoinDerive.hash160(pubkey));
        }
        if (s == Scheme.BitcoinP2wsh) {
            bytes memory witnessScript = abi.decode(p, (bytes));
            return abi.encodePacked(BitcoinDerive.p2wshProgram(witnessScript));
        }
        if (s == Scheme.BitcoinP2sh) {
            bytes memory redeemScript = abi.decode(p, (bytes));
            return abi.encodePacked(BitcoinDerive.p2shScriptHash(redeemScript));
        }

        /* ---------------------------------- Sui --------------------------------- */
        if (s == Scheme.SuiAddress) {
            (uint8 flag, bytes memory pubkey) = abi.decode(p, (uint8, bytes));
            return abi.encodePacked(SuiDerive.addressFromPubkey(flag, pubkey));
        }
        if (s == Scheme.SuiMultisig) {
            (
                uint16 threshold,
                uint8[] memory flags,
                bytes[] memory pubkeys,
                uint8[] memory weights
            ) = abi.decode(p, (uint16, uint8[], bytes[], uint8[]));
            return abi.encodePacked(
                SuiDerive.addressFromMultisig(threshold, flags, pubkeys, weights)
            );
        }
        if (s == Scheme.SuiObjectId) {
            // Derivable but NOT counterfactual: txDigest does not exist until the
            // transaction is built and signed. Use this to VERIFY an object id the
            // destination reported, never to predict one in advance.
            (bytes32 txDigest, uint64 creationNum) = abi.decode(p, (bytes32, uint64));
            return abi.encodePacked(SuiDerive.deriveObjectId(txDigest, creationNum));
        }

        revert UnsupportedScheme(0, uint8(s));
    }
}
