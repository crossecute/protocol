// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ChainRegistry, RegistrySeed, ProviderSeed} from "src/registry/ChainRegistry.sol";
import {ProviderDeployment} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Treasury} from "src/treasury/Treasury.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {CROSS_PROXY_DEPLOYER, crossProxySalt} from "src/account/CrossProxyDeployer.sol";
import {VM, ARACHNID, DeployCheck, check, arachnidDeploy} from "script/deploy/CrossProxyDeploy.sol";
import {ChainConfig, ChainEntry, Derivation} from "script/deploy/ChainConfig.sol";

/// @notice `deploy/governance.toml`.
struct Governance {
    ChainEntry home;
    address owner;
    bytes32 salt;
    uint256 timelockDelay;
    /// The providers whose governor accounts propose and cancel on every timelock.
    string[2] proposers;
    bytes32 crossProxyInitCodeHash;
    /// In the file's key order, which every chain reads identically.
    ProviderSeed[] providers;
}

/// @notice A chain's step-1 contracts.
struct ChainContracts {
    TimelockController timelock;
    ChainRegistry registry;
    Treasury treasury;
}

/// @title GovernanceConfig
/// @notice Reads `deploy/governance.toml`, checking its shape. Unset values (a zero owner, or a zero
///         caller or salt in a provider's record) parse, and are refused by `requireSet`, so the
///         file can be checked before they are decided.
library GovernanceConfig {
    function defaultFile() internal view returns (string memory) {
        return string.concat(ChainConfig.defaultDir(), "/governance.toml");
    }

    function read(string memory file, ChainEntry[] memory cs) internal view returns (Governance memory g) {
        string memory toml = ChainConfig.read(file);
        string memory homeName = VM.parseTomlString(toml, ".home");
        g.home = ChainConfig.chainNamed(cs, homeName);
        check(g.home.derivation == Derivation.Parity, "the governor's home is a parity chain");
        g.owner = VM.parseTomlAddress(toml, ".owner");
        g.salt = VM.parseTomlBytes32(toml, ".salt");
        g.timelockDelay = VM.parseTomlUint(toml, ".timelock_delay");
        check(g.timelockDelay != 0, "the timelock has a delay");
        g.crossProxyInitCodeHash = VM.parseTomlBytes32(toml, ".cross_proxy_init_code_hash");
        check(g.crossProxyInitCodeHash != bytes32(0), "cross_proxy_init_code_hash is set");

        string[] memory names = VM.parseTomlKeys(toml, ".providers");
        g.providers = new ProviderSeed[](names.length);
        for (uint256 i; i < names.length; ++i) {
            string memory key = string.concat(".providers['", names[i], "']");
            g.providers[i] = ProviderSeed({
                name: names[i],
                deployedBy: VM.parseTomlAddress(toml, string.concat(key, ".deployed_by")),
                salt: VM.parseTomlBytes32(toml, string.concat(key, ".salt")),
                crossProxyInitCodeHash: g.crossProxyInitCodeHash
            });
        }

        string[] memory proposers = VM.parseTomlStringArray(toml, ".proposers");
        check(proposers.length == 2, "two proposer providers");
        check(keccak256(bytes(proposers[0])) != keccak256(bytes(proposers[1])), "the proposer providers differ");
        for (uint256 i; i < 2; ++i) {
            providerSeed(g, proposers[i]);
            g.proposers[i] = proposers[i];
        }
    }

    /// @notice The values a deployment hashes into addresses are decided. A salt may repeat across
    ///         providers, since each record's caller is hashed in with it.
    function requireSet(Governance memory g) internal pure {
        check(g.owner != address(0), "governance.toml: owner is set");
        for (uint256 i; i < g.providers.length; ++i) {
            check(g.providers[i].deployedBy != address(0), "governance.toml: every deployed_by is set");
            check(g.providers[i].salt != bytes32(0), "governance.toml: every provider salt is set");
            for (uint256 j; j < i; ++j) {
                check(
                    g.providers[j].deployedBy != g.providers[i].deployedBy
                        || g.providers[j].salt != g.providers[i].salt,
                    "governance.toml: each provider's record is its own"
                );
            }
        }
    }

    function providerSeed(Governance memory g, string memory name) internal pure returns (ProviderSeed memory) {
        for (uint256 i; i < g.providers.length; ++i) {
            if (keccak256(bytes(g.providers[i].name)) == keccak256(bytes(name))) return g.providers[i];
        }
        revert DeployCheck("governance.toml: provider has a record");
    }
}

/// @title ChainDeploy
/// @notice Step 1 of `docs/provider-spec.md` §6 on a parity chain: the timelock, then the registry
///         and treasury it owns, each through Arachnid's factory with arguments taken only from
///         `deploy/`, so each sits at one address on every parity chain.
library ChainDeploy {
    function homeIdentifier(Governance memory g) internal pure returns (bytes memory) {
        return Erc7930.encodeEvmChain(g.home.chainId);
    }

    /// @notice Where the governor's account under `provider` sits on a parity chain: the
    ///         transceiver from its record, then the account from the transceiver, as
    ///         `ChainRegistry.predictCrossAccount` derives them.
    /// @dev On the home this is the governor's transmitter, elsewhere the receiver its bootstrap
    ///      creates, which is each of that provider's transceivers' owner.
    function governorAccount(Governance memory g, string memory provider) internal pure returns (address) {
        return AddressDerive.create2(
            transceiver(g, provider),
            keccak256(abi.encode(g.owner, g.salt, ChainKey.forEvm(g.home.chainId))),
            g.crossProxyInitCodeHash
        );
    }

    /// @notice `provider`'s transceiver, at its record's address on every parity chain.
    function transceiver(Governance memory g, string memory provider) internal pure returns (address) {
        ProviderSeed memory p = GovernanceConfig.providerSeed(g, provider);
        return
            AddressDerive.create2(CROSS_PROXY_DEPLOYER, crossProxySalt(p.deployedBy, p.salt), g.crossProxyInitCodeHash);
    }

    function proposers(Governance memory g) internal pure returns (address[] memory ps) {
        ps = new address[](2);
        ps[0] = governorAccount(g, g.proposers[0]);
        ps[1] = governorAccount(g, g.proposers[1]);
    }

    function seed(Governance memory g) internal pure returns (RegistrySeed memory) {
        return RegistrySeed({
            governorHome: homeIdentifier(g), governorHomeGrade: Provenance.Predetermined, providers: g.providers
        });
    }

    function timelockInitCode(Governance memory g) internal pure returns (bytes memory) {
        address[] memory executors = new address[](1); // zero: execution is open
        return abi.encodePacked(
            type(TimelockController).creationCode, abi.encode(g.timelockDelay, proposers(g), executors, address(0))
        );
    }

    function registryInitCode(Governance memory g, address timelock) internal pure returns (bytes memory) {
        return abi.encodePacked(type(ChainRegistry).creationCode, abi.encode(timelock, seed(g)));
    }

    function treasuryInitCode(address timelock) internal pure returns (bytes memory) {
        return abi.encodePacked(type(Treasury).creationCode, abi.encode(timelock));
    }

    /// @notice Where `deploy` puts them, before it runs.
    function predict(Governance memory g) internal pure returns (ChainContracts memory c) {
        address timelock = _arachnidAddress(timelockInitCode(g));
        c.timelock = TimelockController(payable(timelock));
        c.registry = ChainRegistry(_arachnidAddress(registryInitCode(g, timelock)));
        c.treasury = Treasury(payable(_arachnidAddress(treasuryInitCode(timelock))));
    }

    /// @notice Deploy what is missing and check all three. Rerunning deploys nothing.
    function deploy(Governance memory g) internal returns (ChainContracts memory c) {
        address timelock = arachnidDeploy(timelockInitCode(g));
        c.timelock = TimelockController(payable(timelock));
        c.registry = ChainRegistry(arachnidDeploy(registryInitCode(g, timelock)));
        c.treasury = Treasury(payable(arachnidDeploy(treasuryInitCode(timelock))));
        checkChain(g, c);
    }

    /// @notice The design `docs/provider-spec.md` §6 step 1 states, read back from chain.
    /// @dev Only the timelock itself may hold its admin role. Roles cannot be enumerated, so
    ///      that rests on the constructor arguments, which `predict` fixes: a timelock at the
    ///      predicted address was built with no admin.
    function checkChain(Governance memory g, ChainContracts memory c) internal view {
        ChainContracts memory p = predict(g);
        check(address(c.timelock) == address(p.timelock), "the timelock is where governance.toml predicts");
        check(address(c.registry) == address(p.registry), "the registry is where governance.toml predicts");
        check(address(c.treasury) == address(p.treasury), "the treasury is where governance.toml predicts");

        TimelockController t = c.timelock;
        check(t.getMinDelay() == g.timelockDelay, "the timelock's delay");
        address[] memory ps = proposers(g);
        for (uint256 i; i < ps.length; ++i) {
            check(t.hasRole(t.PROPOSER_ROLE(), ps[i]), "a governor account proposes");
            check(t.hasRole(t.CANCELLER_ROLE(), ps[i]), "a governor account cancels");
        }
        check(t.hasRole(t.EXECUTOR_ROLE(), address(0)), "execution is open");

        check(c.registry.owner() == address(t), "the timelock owns the registry");
        check(c.treasury.owner() == address(t), "the timelock owns the treasury");
        bytes32 home = ChainKey.forEvm(g.home.chainId);
        check(c.registry.hasChainKey(home), "the registry has the governor's home");
        check(c.registry.provenanceFor(home) == Provenance.Predetermined, "the governor's home is Predetermined");
        for (uint256 i; i < g.providers.length; ++i) {
            ProviderDeployment memory r = c.registry.providerDeployment(keccak256(bytes(g.providers[i].name)));
            check(
                r.deployedBy == g.providers[i].deployedBy && r.salt == g.providers[i].salt
                    && r.crossProxyInitCodeHash == g.crossProxyInitCodeHash,
                "the registry records each provider as governance.toml does"
            );
        }
    }

    function _arachnidAddress(bytes memory initCode) private pure returns (address) {
        return Create2.computeAddress(bytes32(0), keccak256(initCode), ARACHNID);
    }
}
