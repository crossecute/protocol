// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {CrossProxy} from "src/account/CrossProxy.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {ChainRegistry, ProviderSeed} from "src/registry/ChainRegistry.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {DeployCheck} from "script/deploy/CrossProxyDeploy.sol";
import {ChainConfig} from "script/deploy/ChainConfig.sol";
import {Governance, GovernanceConfig, ChainContracts, ChainDeploy} from "script/deploy/ChainDeploy.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {CcipDeploy} from "script/deploy/CcipDeploy.sol";
import {DeployChain} from "script/DeployChain.s.sol";
import {testGovernanceFile, testGovernance, skipUnderCoverage} from "test/deploy/TestGovernance.sol";

contract DeployChainWithTestConfig is DeployChain {
    function _governanceFile() internal view override returns (string memory) {
        return testGovernanceFile();
    }
}

contract DeployChainTest is Test {
    DeployChain internal script;
    Governance internal g;

    function setUp() public {
        script = new DeployChainWithTestConfig();
        Governance memory read = testGovernance();
        g.home = read.home;
        g.owner = read.owner;
        g.salt = read.salt;
        g.timelockDelay = read.timelockDelay;
        g.proposers = read.proposers;
        g.crossProxyInitCodeHash = read.crossProxyInitCodeHash;
        for (uint256 i; i < read.providers.length; ++i) {
            g.providers.push(read.providers[i]);
        }
    }

    function _runOn(uint256 chainId) internal returns (ChainContracts memory) {
        vm.chainId(chainId);
        return script.run();
    }

    function test_theContractsLandAtOneAddressOnEveryParityChain() public {
        skipUnderCoverage();
        uint256 snapshot = vm.snapshotState();
        ChainContracts memory onHome = _runOn(1);
        vm.revertToState(snapshot);
        ChainContracts memory onBase = _runOn(8453);

        assertEq(address(onHome.timelock), address(onBase.timelock));
        assertEq(address(onHome.registry), address(onBase.registry));
        assertEq(address(onHome.treasury), address(onBase.treasury));
        assertEq(address(onBase.registry), address(ChainDeploy.predict(g).registry));
    }

    function test_aRerunDeploysNothing() public {
        skipUnderCoverage();
        ChainContracts memory first = _runOn(8453);
        ChainContracts memory second = script.run();
        assertEq(address(first.registry), address(second.registry));
    }

    /// @dev The timelock is built from accounts step 1 predicts; they must be the ones each
    ///      step-2 transceiver names as its owner, or no governor could ever propose.
    function test_aProposerIsTheOwnerItsTransceiverIsBornWith() public {
        skipUnderCoverage();
        ChainContracts memory c = _runOn(8453);
        ProviderSeed memory record = GovernanceConfig.providerSeed(g, "ccip");
        address router = address(new RouterStub());
        TransceiverDeployment memory d = TransceiverDeployment({
            deployedBy: record.deployedBy,
            salt: record.salt,
            implementation: CcipDeploy.transceiverImplementation(router),
            config: TransceiverConfig({
                gateways: new address[](0),
                transmitterImplementation: CcipDeploy.transmitterImplementation(router),
                receiverImplementation: CcipDeploy.receiverImplementation(router),
                governorOwner: g.owner,
                governorSalt: g.salt,
                governorHome: ChainDeploy.homeIdentifier(g),
                treasury: address(c.treasury),
                chainRegistry: IChainRegistryRefs(address(c.registry)),
                messageProvider: keccak256("ccip"),
                minCounterpartProvenance: Provenance.Unique
            })
        });
        uint64 homeSelector = uint64(
            ChainConfig.providerId(
                ChainConfig.defaultDir(), ChainConfig.chains(ChainConfig.defaultDir()), "ccip", g.home
            )
        );
        vm.startPrank(record.deployedBy);
        address t = CcipDeploy.transceiver(d, router, homeSelector);
        vm.stopPrank();

        address governor = TransceiverBase(payable(t)).owner();
        assertEq(governor, ChainDeploy.governorAccount(g, "ccip"));
        assertTrue(c.timelock.hasRole(c.timelock.PROPOSER_ROLE(), governor));
    }

    /// @dev A governor account schedules, anyone executes after the delay, and the registry
    ///      takes the call: the timelock owns it.
    function test_aProposalReachesTheRegistryAfterTheDelay() public {
        skipUnderCoverage();
        ChainContracts memory c = _runOn(8453);
        address proposer = ChainDeploy.governorAccount(g, "layerzero");
        bytes memory call =
            abi.encodeCall(ChainRegistry.addChainKey, (Erc7930.encodeEvmChain(10), Provenance.Predetermined));

        vm.prank(proposer);
        c.timelock.schedule(address(c.registry), 0, call, bytes32(0), bytes32(0), g.timelockDelay);
        vm.expectRevert();
        c.timelock.execute(address(c.registry), 0, call, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + g.timelockDelay);
        vm.prank(address(0xA11CE));
        c.timelock.execute(address(c.registry), 0, call, bytes32(0), bytes32(0));
        assertTrue(c.registry.hasChainKey(ChainKey.forEvm(10)));
    }

    function test_aNonParityChainIsRefused() public {
        vm.chainId(324);
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "this chain is a parity chain"));
        script.run();
    }

    /// @dev Production's file is not ready to deploy until its addresses are decided.
    function test_theProductionFileRefusesItsUnsetOwner() public {
        DeployChain production = new DeployChain();
        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "governance.toml: owner is set"));
        production.run();
    }

    /// @dev The registry records this value for every provider, so it must be solc's (R8.4).
    function test_theProductionFileRecordsThisBuildsInitCodeHash() public {
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) vm.skip(true);
        Governance memory p =
            GovernanceConfig.read(GovernanceConfig.defaultFile(), ChainConfig.chains(ChainConfig.defaultDir()));
        assertEq(p.crossProxyInitCodeHash, keccak256(type(CrossProxy).creationCode));
    }
}

/// @dev `CcipTransceiver`'s constructor and initializer read nothing from the router.
contract RouterStub {}
