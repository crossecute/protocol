// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {IChainRegistryRefs, ProviderDeployment} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {check} from "script/deploy/CrossProxyDeploy.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";

/// @title DeployProvider
/// @notice Step 2 of `docs/provider-spec.md` §6 for one provider on one standard EVM chain:
///         its account implementations, its transceiver implementation, and the transceiver,
///         deployed through `CrossProxyDeployer` from the registry's record.
///
/// @dev Chain-wide inputs, from the environment:
///      `CHAIN_REGISTRY`, `TREASURY`, `GOVERNOR_OWNER`, `GOVERNOR_SALT` (default zero),
///      `GOVERNOR_HOME_CHAIN_ID`, `MIN_COUNTERPART_PROVENANCE` (0 Unknown, 1 Unique,
///      2 Predetermined), and `GATEWAYS` (default none; they cannot be added later).
///      Each provider's script names its own.
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
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        (address receiverImpl, address transmitterImpl, address transceiverImpl) = _implementations();
        TransceiverDeployment memory d = _fromRecord(deployer, transceiverImpl, _config(receiverImpl, transmitterImpl));
        transceiver = _deploy(d);
        vm.stopBroadcast();
    }

    function _config(address receiverImpl, address transmitterImpl) internal view returns (TransceiverConfig memory) {
        uint256 bar = vm.envUint("MIN_COUNTERPART_PROVENANCE");
        check(bar <= uint256(Provenance.Predetermined), "MIN_COUNTERPART_PROVENANCE names a grade");
        return TransceiverConfig({
            gateways: vm.envOr("GATEWAYS", ",", new address[](0)),
            transmitterImplementation: transmitterImpl,
            receiverImplementation: receiverImpl,
            governorOwner: vm.envAddress("GOVERNOR_OWNER"),
            governorSalt: vm.envOr("GOVERNOR_SALT", bytes32(0)),
            governorHome: Erc7930.encodeEvmChain(vm.envUint("GOVERNOR_HOME_CHAIN_ID")),
            treasury: vm.envAddress("TREASURY"),
            chainRegistry: IChainRegistryRefs(vm.envAddress("CHAIN_REGISTRY")),
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
        check(address(c.chainRegistry).code.length != 0, "CHAIN_REGISTRY is deployed");
        ProviderDeployment memory r = c.chainRegistry.providerDeployment(c.messageProvider);
        check(r.salt != bytes32(0), "the registry records this provider's deployment");
        check(r.deployedBy == deployer, "the broadcaster is the recorded deployedBy");
        return TransceiverDeployment({deployedBy: deployer, salt: r.salt, implementation: implementation, config: c});
    }

    /// @notice The provider's id for the governor's home, which the bootstrap that creates the
    ///         owner arrives under. Required unless this chain is the home.
    function _governorHomeId(string memory name) internal view returns (uint256 id) {
        id = vm.envOr(name, uint256(0));
        if (vm.envUint("GOVERNOR_HOME_CHAIN_ID") != block.chainid) check(id != 0, name);
    }
}
