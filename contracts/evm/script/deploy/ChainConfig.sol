// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Provenance} from "src/registry/Provenance.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {VM, DeployCheck, check} from "script/deploy/ProxyDeploy.sol";

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
    ///      is nonzero, unique, and fits the provider's `id_bits`.
    function providerId(string memory dir, ChainEntry[] memory cs, string memory provider, ChainEntry memory c)
        internal
        view
        returns (uint256)
    {
        (string[] memory names, uint256[] memory ids) = _providerIds(read(_providerFile(dir, provider)), cs);
        return _idNamed(names, ids, c.name);
    }

    /// @notice `provider`'s id for `remote` as `local`'s transceiver names it, or zero where it
    ///         does not carry `local` to `remote`: either chain has no id, or the file's
    ///         `[blocked]` table lists `remote` under `local`.
    /// @dev `[blocked]` is directional, keyed by sender, and checked as the ids are.
    function routeId(
        string memory dir,
        ChainEntry[] memory cs,
        string memory provider,
        ChainEntry memory local,
        ChainEntry memory remote
    ) internal view returns (uint256) {
        string memory toml = read(_providerFile(dir, provider));
        (string[] memory names, uint256[] memory ids) = _providerIds(toml, cs);
        uint256 localId = _idNamed(names, ids, local.name);
        uint256 remoteId = _idNamed(names, ids, remote.name);
        if (localId == 0 || remoteId == 0 || local.chainId == remote.chainId) return 0;
        if (!VM.keyExistsToml(toml, ".blocked")) return remoteId;
        string[] memory senders = VM.parseTomlKeys(toml, ".blocked");
        for (uint256 i; i < senders.length; ++i) {
            check(_idNamed(names, ids, senders[i]) != 0, "blocked senders have provider ids");
            string[] memory receivers = VM.parseTomlStringArray(toml, string.concat(".blocked.", senders[i]));
            for (uint256 j; j < receivers.length; ++j) {
                check(_idNamed(names, ids, receivers[j]) != 0, "blocked receivers have provider ids");
                check(!_same(senders[i], receivers[j]), "a chain is not blocked from itself");
                if (_same(senders[i], local.name) && _same(receivers[j], remote.name)) return 0;
            }
        }
        return remoteId;
    }

    /// @notice LayerZero Labs' DVN on `local` for its pathway to `remote`, or zero where
    ///         LayerZero's defaults verify it. A pathway is pinned where either end is listed in
    ///         `layerzero.toml`'s `pinned`, whose every pathway defaults to the dead DVN.
    /// @dev Checks each pinned name is a configured chain, and that `local` has a DVN listed.
    function lzDvn(string memory dir, ChainEntry[] memory cs, ChainEntry memory local, ChainEntry memory remote)
        internal
        view
        returns (address)
    {
        string memory toml = read(_providerFile(dir, "layerzero"));
        if (!VM.keyExistsToml(toml, ".pinned")) return address(0);
        string[] memory pinned = VM.parseTomlStringArray(toml, ".pinned");
        bool pin;
        for (uint256 i; i < pinned.length; ++i) {
            check(hasChainNamed(cs, pinned[i]), "pinned LayerZero chains are chains.toml names");
            if (_same(pinned[i], local.name) || _same(pinned[i], remote.name)) pin = true;
        }
        if (!pin) return address(0);
        string memory key = string.concat(".dvns.", local.name);
        check(VM.keyExistsToml(toml, key), "a chain on a pinned LayerZero pathway lists its DVN");
        address dvn = VM.parseTomlAddress(toml, key);
        check(dvn != address(0), "a listed LayerZero DVN is nonzero");
        return dvn;
    }

    function _providerFile(string memory dir, string memory provider) private pure returns (string memory) {
        return string.concat(dir, "/providers/", provider, ".toml");
    }

    function _providerIds(string memory toml, ChainEntry[] memory cs)
        private
        pure
        returns (string[] memory names, uint256[] memory ids)
    {
        uint256 bits = VM.parseTomlUint(toml, ".id_bits");
        check(bits != 0 && bits <= 256, "id_bits is a width");
        names = VM.parseTomlKeys(toml, ".ids");
        ids = new uint256[](names.length);
        for (uint256 i; i < names.length; ++i) {
            check(hasChainNamed(cs, names[i]), "provider ids are keyed by chains.toml names");
            ids[i] = VM.parseTomlUint(toml, string.concat(".ids.", names[i]));
            check(ids[i] != 0, "provider id is nonzero");
            check(bits == 256 || ids[i] >> bits == 0, "provider id fits id_bits");
            for (uint256 j; j < i; ++j) {
                check(ids[j] != ids[i], "provider id is unique");
            }
        }
    }

    function _idNamed(string[] memory names, uint256[] memory ids, string memory name) private pure returns (uint256) {
        for (uint256 i; i < names.length; ++i) {
            if (_same(names[i], name)) return ids[i];
        }
        return 0;
    }

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @notice The grade `registryChain`'s registry gives `graded`: `Predetermined` when
    ///         `graded` is a parity chain and `registryChain` is not `other`, else `Unique`.
    /// @dev A parity chain's transceivers sit where the registry predicts, from the deployer
    ///      recorded for the chain. A standard EVM transceiver on an `other` chain sits elsewhere, so it
    ///      can use no parity address (#33). A non-parity chain is
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

    function chainNamed(ChainEntry[] memory cs, string memory name) internal pure returns (ChainEntry memory) {
        for (uint256 i; i < cs.length; ++i) {
            if (keccak256(bytes(cs[i].name)) == keccak256(bytes(name))) return cs[i];
        }
        revert DeployCheck("chain name is in chains.toml");
    }

    function hasChainNamed(ChainEntry[] memory cs, string memory name) internal pure returns (bool) {
        for (uint256 i; i < cs.length; ++i) {
            if (keccak256(bytes(cs[i].name)) == keccak256(bytes(name))) return true;
        }
        return false;
    }
}
