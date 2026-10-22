// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {IChainRegistryRefs, ProviderDeployment} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {check} from "script/deploy/CrossProxyDeploy.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {ChainConfig, ChainEntry, Derivation} from "script/deploy/ChainConfig.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {Governance, GovernanceConfig, ChainContracts, ChainDeploy} from "script/deploy/ChainDeploy.sol";

/// @title DeployProvider
/// @notice Step 2 of `docs/provider-spec.md` §6 for one provider on one standard EVM chain:
///         its account implementations, its transceiver implementation, and the transceiver,
///         deployed through `CrossProxyDeployer` from the registry's record.
///
/// @dev The governor's owner, salt, and home come from `deploy/governance.toml`, and the
///      registry and treasury are step 1's, at the addresses that file predicts. From the
///      environment: `MIN_COUNTERPART_PROVENANCE` (0 Unknown, 1 Unique, 2 Predetermined) and
///      `GATEWAYS` (default none; they cannot be added later). Each provider's script names
///      its endpoints. Provider ids come from `deploy/`.
///
/// @dev The checks every deployment shares live in `script/deploy/`, which the tests deploy
///      through. What is checked here holds only in production: the salt and caller are the
///      registry's record, never chosen, and the governor home's id is given.
abstract contract DeployProvider is Script {
    /// @notice The provider's name in the registry, hashed into its key.
    function _providerName() internal pure virtual returns (string memory);

    function _implementations()
        internal
        virtual
        returns (address receiverImplementation, address transmitterImplementation, address transceiverImplementation);

    function _deploy(TransceiverDeployment memory d) internal virtual returns (address transceiver);

    function run() external returns (address transceiver) {
        Governance memory g = _governance();
        GovernanceConfig.requireSet(g);
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        (address receiverImpl, address transmitterImpl, address transceiverImpl) = _implementations();
        TransceiverConfig memory c = _config(g, receiverImpl, transmitterImpl);
        _checkChains(g, ChainRegistry(address(c.chainRegistry)));
        TransceiverDeployment memory d = _fromRecord(deployer, transceiverImpl, c);
        transceiver = _deploy(d);
        vm.stopBroadcast();
    }

    function _config(Governance memory g, address receiverImpl, address transmitterImpl)
        internal
        view
        returns (TransceiverConfig memory)
    {
        uint256 bar = vm.envUint("MIN_COUNTERPART_PROVENANCE");
        check(bar <= uint256(Provenance.Predetermined), "MIN_COUNTERPART_PROVENANCE names a grade");
        ChainContracts memory step1 = ChainDeploy.predict(g);
        return TransceiverConfig({
            gateways: vm.envOr("GATEWAYS", ",", new address[](0)),
            transmitterImplementation: transmitterImpl,
            receiverImplementation: receiverImpl,
            governorOwner: g.owner,
            governorSalt: g.salt,
            governorHome: ChainDeploy.homeIdentifier(g),
            treasury: address(step1.treasury),
            chainRegistry: IChainRegistryRefs(address(step1.registry)),
            messageProvider: keccak256(bytes(_providerName())),
            minCounterpartProvenance: Provenance(bar)
        });
    }

    /// @dev Every chain must put the transceiver at one address, so the salt and caller are the
    ///      ones the registry was seeded with on every chain.
    function _fromRecord(address deployer, address implementation, TransceiverConfig memory c)
        internal
        view
        returns (TransceiverDeployment memory)
    {
        check(address(c.chainRegistry).code.length != 0, "step 1's registry is deployed");
        ProviderDeployment memory r = c.chainRegistry.providerDeployment(c.messageProvider);
        check(r.salt != bytes32(0), "the registry records this provider's deployment");
        check(r.deployedBy == deployer, "the broadcaster is the recorded deployedBy");
        return TransceiverDeployment({deployedBy: deployer, salt: r.salt, implementation: implementation, config: c});
    }

    /// @notice This chain and the governor's home are configured, this chain is a parity chain
    ///         (zkSync and Tron are built by other compilers), the home is `Predetermined` from
    ///         here as birth requires, the registry has the home, and its grades agree with
    ///         `deploy/`.
    function _checkChains(Governance memory g, ChainRegistry registry) internal view {
        ChainEntry[] memory cs = ChainConfig.chains(ChainConfig.defaultDir());
        ChainEntry memory local = ChainConfig.chainWithId(cs, block.chainid);
        check(local.derivation == Derivation.Parity, "this chain is a parity chain");
        ChainEntry memory home = g.home;
        check(ChainConfig.gradeOf(local, home) == Provenance.Predetermined, "the governor's home is Predetermined");
        // The initializer would revert `UnknownChainKey` without saying which chain is missing.
        if (home.chainId != block.chainid) {
            check(registry.hasChainKey(ChainKey.forEvm(home.chainId)), "the registry has the governor's home");
        }
        ChainConfig.checkRegistryGrades(registry, cs, local);
    }

    /// @notice The provider's id for the governor's home, which the bootstrap that creates the
    ///         owner arrives under. Required unless this chain is the home.
    function _governorHomeId() internal view returns (uint256 id) {
        string memory dir = ChainConfig.defaultDir();
        ChainEntry memory home = _governance().home;
        id = ChainConfig.providerId(dir, ChainConfig.chains(dir), _providerName(), home);
        if (home.chainId != block.chainid) check(id != 0, "the provider reaches the governor's home");
    }

    function _governance() internal view returns (Governance memory) {
        return GovernanceConfig.read(_governanceFile(), ChainConfig.chains(ChainConfig.defaultDir()));
    }

    /// @dev Overridden by tests, whose file has every value set.
    function _governanceFile() internal view virtual returns (string memory) {
        return GovernanceConfig.defaultFile();
    }
}
