// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CrossProxy} from "src/account/CrossProxy.sol";
import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {ChainRegistry, RegistrySeed, ProviderSeed} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {DeployCheck, deployCrossProxy} from "script/deploy/CrossProxyDeploy.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {LzDeploy} from "script/deploy/LzDeploy.sol";
import {LzFixture} from "test/protocols/layerzero/LzFixture.sol";

/// @notice The checks every transceiver deploy shares, run on LayerZero's: they do not depend
///         on the provider. Every provider suite deploys through them on the passing path.
contract DeployChecksTest is LzFixture {
    bytes32 constant SALT = keccak256("salt");
    uint32 constant HOME_EID = 30101;

    /// @dev External so that an expected revert attaches to the whole deploy.
    function deploy(TransceiverDeployment memory d) external returns (address) {
        return LzDeploy.transceiver(d, HOME_EID, address(0));
    }

    function _seeded(address deployedBy, bytes32 salt, bytes32 initCodeHash) internal returns (ChainRegistry) {
        ProviderSeed[] memory providers = new ProviderSeed[](1);
        providers[0] = ProviderSeed("layerzero", deployedBy, salt, initCodeHash);
        return new ChainRegistry(
            address(this),
            RegistrySeed({
                governorHome: Erc7930.encodeEvmChain(1),
                governorHomeGrade: Provenance.Predetermined,
                providers: providers
            })
        );
    }

    function _from(ChainRegistry registry, address deployedBy, bytes32 salt)
        internal
        returns (TransceiverDeployment memory d)
    {
        TransceiverConfig memory c = _config();
        c.chainRegistry = IChainRegistryRefs(address(registry));
        c.messageProvider = keccak256("layerzero");
        c.minCounterpartProvenance = Provenance.Unique;
        d = TransceiverDeployment({
            deployedBy: deployedBy, salt: salt, implementation: _transceiverImplementation(), config: c
        });
    }

    function _expect(string memory what) internal {
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, what));
    }

    /// @dev C21, script side: deployed from the record, the transceiver is where the registry
    ///      predicts on every `Predetermined` chain.
    function test_aDeploymentFromTheRecordLandsWhereTheRegistryPredicts() public {
        ChainRegistry registry = _seeded(address(this), SALT, keccak256(type(CrossProxy).creationCode));
        address t = this.deploy(_from(registry, address(this), SALT));
        assertEq(t, registry.predictTransceiver(ChainKey.forEvm(1), keccak256("layerzero")));
    }

    /// @dev R8.4: a record whose initcode hash is not solc's predicts every transceiver and
    ///      account somewhere else.
    function test_aRecordedInitCodeHashThatIsNotSolcsIsRefused() public {
        ChainRegistry registry = _seeded(address(this), SALT, keccak256("zksolc"));
        TransceiverDeployment memory d = _from(registry, address(this), SALT);
        _expect("recorded initcode hash is solc's (R8.4)");
        this.deploy(d);
    }

    function test_aSaltOtherThanTheRecordedOneIsRefused() public {
        ChainRegistry registry = _seeded(address(this), SALT, keccak256(type(CrossProxy).creationCode));
        TransceiverDeployment memory d = _from(registry, address(this), keccak256("another"));
        _expect("salt is the recorded one");
        this.deploy(d);
    }

    function test_aCallerOtherThanTheRecordedOneIsRefused() public {
        ChainRegistry registry = _seeded(address(0xD3), SALT, keccak256(type(CrossProxy).creationCode));
        TransceiverDeployment memory d = _from(registry, address(this), SALT);
        _expect("deployedBy is the recorded one");
        this.deploy(d);
    }

    /// @dev The caller is hashed into the address, so naming another one cannot pass.
    function test_misnamingTheCallerIsRefused() public {
        TransceiverDeployment memory d = _from(ChainRegistry(address(0)), address(0xD3), SALT);
        _expect("proxy is where deployedBy and salt predict");
        this.deploy(d);
    }

    function test_anImplementationWithNoCodeIsRefused() public {
        _expect("implementation has code");
        this.deployProxy(address(0x1234));
    }

    function deployProxy(address implementation) external returns (address) {
        return deployCrossProxy(address(this), SALT, implementation, "");
    }
}
