// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Provenance} from "src/registry/Provenance.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {VM, DeployCheck, check} from "script/deploy/CrossProxyDeploy.sol";

/// @notice How a chain places contracts. See `deploy/chains.toml`.
enum Derivation {
    Parity,
    ZkSync,
    Tron,
    Other
}

struct ChainEntry {
    string name;
    uint256 chainId;
    Derivation derivation;
}

/// @title ChainConfig
/// @notice Reads `deploy/chains.toml` and `deploy/providers/<provider>.toml`, checking them as it
///         goes, so a malformed or contradictory file fails a test and a deployment alike.
library ChainConfig {
    function defaultDir() internal view returns (string memory) {
        return string.concat(VM.projectRoot(), "/deploy");
    }

    /// @notice Every configured chain, with unique nonzero chain ids and a known derivation.
    function chains(string memory dir) internal view returns (ChainEntry[] memory cs) {
        string memory toml = read(string.concat(dir, "/chains.toml"));
        string[] memory names = VM.parseTomlKeys(toml, ".chains");
        cs = new ChainEntry[](names.length);
        for (uint256 i; i < names.length; ++i) {
            string memory key = string.concat(".chains.", names[i]);
            cs[i] = ChainEntry({
                name: names[i],
                chainId: VM.parseTomlUint(toml, string.concat(key, ".chain_id")),
                derivation: _derivation(VM.parseTomlString(toml, string.concat(key, ".derivation")))
            });
            check(cs[i].chainId != 0, "chain_id is nonzero");
            for (uint256 j; j < i; ++j) {
                check(cs[j].chainId != cs[i].chainId, "chain_id is unique");
            }
        }
    }

    function chainWithId(ChainEntry[] memory cs, uint256 chainId) internal pure returns (ChainEntry memory) {
        for (uint256 i; i < cs.length; ++i) {
            if (cs[i].chainId == chainId) return cs[i];
        }
        revert DeployCheck("chain_id is in chains.toml");
    }

    /// @notice `provider`'s id for `c`, or zero where the provider does not reach it.
    /// @dev Checks the whole file each time: every key names a configured chain, and every id
    ///      is nonzero, unique, and fits the provider's width.
    function providerId(string memory dir, ChainEntry[] memory cs, string memory provider, ChainEntry memory c)
        internal
        view
        returns (uint256 id)
    {
        string memory toml = read(string.concat(dir, "/providers/", provider, ".toml"));
        uint256 bits = VM.parseTomlUint(toml, ".id_bits");
        check(bits != 0 && bits <= 256, "id_bits is a width");
        string[] memory names = VM.parseTomlKeys(toml, ".ids");
        uint256[] memory ids = new uint256[](names.length);
        for (uint256 i; i < names.length; ++i) {
            check(hasChainNamed(cs, names[i]), "provider ids are keyed by chains.toml names");
            ids[i] = VM.parseTomlUint(toml, string.concat(".ids.", names[i]));
            check(ids[i] != 0, "provider id is nonzero");
            check(bits == 256 || ids[i] >> bits == 0, "provider id fits id_bits");
            for (uint256 j; j < i; ++j) {
                check(ids[j] != ids[i], "provider id is unique");
            }
            if (keccak256(bytes(names[i])) == keccak256(bytes(c.name))) id = ids[i];
        }
    }

    /// @notice The grade `registryChain`'s registry gives `graded`: `Predetermined` when
    ///         `graded` is a parity chain and `registryChain` is not `other`, else `Unique`.
    /// @dev A parity chain's transceivers sit where the provider's record predicts. A plain
    ///      transceiver finds that address at its own, and a zkSync or Tron one derives it from
    ///      the record (`DivergentTransceiver._parityAddress`). A plain transceiver on an `other`
    ///      chain sits elsewhere, so it can use no parity address (#33). A non-parity chain is
    ///      `Unique` in every registry, its own included. Configuration never assigns `Unknown`.
    function gradeOf(ChainEntry memory registryChain, ChainEntry memory graded) internal pure returns (Provenance) {
        return graded.derivation == Derivation.Parity && registryChain.derivation != Derivation.Other
            ? Provenance.Predetermined
            : Provenance.Unique;
    }

    /// @notice Every configured chain `registry` (on `local`) has registered carries the grade
    ///         this configuration gives it. A grade is write-once, so a mismatch is permanent.
    function checkRegistryGrades(ChainRegistry registry, ChainEntry[] memory cs, ChainEntry memory local)
        internal
        view
    {
        for (uint256 i; i < cs.length; ++i) {
            bytes32 chainKey = ChainKey.forEvm(cs[i].chainId);
            if (!registry.hasChainKey(chainKey)) continue;
            check(registry.provenanceFor(chainKey) == gradeOf(local, cs[i]), "registry grades agree with chains.toml");
        }
    }

    /// @dev `fs_permissions` in foundry.toml limits reads to `deploy/` and the test configs.
    function read(string memory path) internal view returns (string memory) {
        // forge-lint: disable-next-line(unsafe-cheatcode) reads the configuration, nothing else
        return VM.readFile(path);
    }

    function _derivation(string memory s) private pure returns (Derivation) {
        bytes32 h = keccak256(bytes(s));
        if (h == keccak256("parity")) return Derivation.Parity;
        if (h == keccak256("zksync")) return Derivation.ZkSync;
        if (h == keccak256("tron")) return Derivation.Tron;
        if (h == keccak256("other")) return Derivation.Other;
        revert DeployCheck("derivation is parity, zksync, tron, or other");
    }

    function hasChainNamed(ChainEntry[] memory cs, string memory name) internal pure returns (bool) {
        for (uint256 i; i < cs.length; ++i) {
            if (keccak256(bytes(cs[i].name)) == keccak256(bytes(name))) return true;
        }
        return false;
    }
}
