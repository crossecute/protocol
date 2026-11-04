// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Status} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Call} from "src/messaging/Call.sol";
import {DeployCheck} from "script/deploy/CrossProxyDeploy.sol";
import {ChainConfig, ChainEntry} from "script/deploy/ChainConfig.sol";
import {ChainContracts, ChainDeploy} from "script/deploy/ChainDeploy.sol";
import {Plan, Tx, PendingPair, GovernancePlan} from "script/deploy/GovernancePlan.sol";
import {RotateDeployer} from "script/RotateDeployer.s.sol";
import {testGovernanceFile, skipUnderCoverage} from "test/deploy/TestGovernance.sol";

contract RotateDeployerWithTestConfig is RotateDeployer {
    address internal immutable NEW_DEPLOYER;
    string internal name;
    string[] internal chains;
    string[] internal providers;

    constructor(string memory name_, address newDeployer, string[] memory chains_, string[] memory providers_) {
        name = name_;
        NEW_DEPLOYER = newDeployer;
        chains = chains_;
        providers = providers_;
    }

    function _newDeployer() internal view override returns (address) {
        return NEW_DEPLOYER;
    }

    function _pendingChains() internal view override returns (string[] memory) {
        return chains;
    }

    function _pendingProviders() internal view override returns (string[] memory) {
        return providers;
    }

    function _governanceFile() internal view override returns (string memory) {
        return testGovernanceFile();
    }

    function _outDir() internal view override returns (string memory) {
        return string.concat(vm.projectRoot(), "/out/rotation/test/", name);
    }
}

/// @notice The rotation, run as the timelock of each chain would receive it: scheduled by the first
///         proposer's conduit, refused before the delay, and executed by anyone after it.
contract RotateDeployerTest is Test {
    address constant NEW = address(0x4E77);
    string constant LZ = "layerzero";

    function _plan() internal view returns (Plan memory) {
        return GovernancePlan.load(ChainConfig.defaultDir(), testGovernanceFile());
    }

    function _none() internal pure returns (PendingPair[] memory) {
        return new PendingPair[](0);
    }

    function _script(string memory name, address newDeployer, string memory chain, string memory provider)
        internal
        returns (RotateDeployer)
    {
        string[] memory chains = new string[](bytes(chain).length == 0 ? 0 : 1);
        string[] memory providers = new string[](bytes(provider).length == 0 ? 0 : 1);
        if (chains.length != 0) chains[0] = chain;
        if (providers.length != 0) providers[0] = provider;
        return new RotateDeployerWithTestConfig(name, newDeployer, chains, providers);
    }

    /// @dev Step 1 on `chain`, then the rotation as its timelock receives it.
    function _rotate(Plan memory p, ChainEntry memory chain, PendingPair[] memory pending)
        internal
        returns (ChainContracts memory c, uint256 scheduleGas)
    {
        vm.chainId(chain.chainId);
        c = ChainDeploy.deploy(p.g);
        Call memory schedule = GovernancePlan.scheduleRotation(p, NEW, pending);
        Tx memory execute = GovernancePlan.executeRotation(p, NEW, pending);

        vm.prank(GovernancePlan.governor(p, p.g.proposers[0]));
        uint256 before = gasleft();
        (bool ok,) = schedule.target.call(schedule.data);
        scheduleGas = before - gasleft();
        assertTrue(ok, "the first proposer schedules it");

        (bool early,) = execute.to.call(execute.data);
        assertFalse(early, "not before the delay");
        vm.warp(block.timestamp + p.g.timelockDelay);
        (bool done,) = execute.to.call(execute.data);
        assertTrue(done, "anyone executes it after");
    }

    /* ================================ on every chain ============================== */

    function test_everyChainsRegistryRotatesAfterTheDelay() public {
        skipUnderCoverage();
        Plan memory p = _plan();
        bytes32 lz = keccak256(bytes(LZ));
        bytes32 homeKey = ChainKey.forEvm(p.g.home.chainId);
        for (uint256 i; i < p.chains.length; ++i) {
            uint256 world = vm.snapshotState();
            (ChainContracts memory c, uint256 gas) = _rotate(p, p.chains[i], _none());

            assertEq(c.registry.currentDeployer(), NEW, p.chains[i].name);
            assertEq(c.registry.deployedBy(homeKey, lz), p.g.deployer, "nothing recorded moves");
            assertTrue(c.registry.isLive(homeKey, lz));
            assertLe(gas * 11 / 10, GovernancePlan.CALL_GAS + GovernancePlan.SCHEDULE_ENTRY_GAS, "the delivery budget");
            vm.revertToState(world);
        }
    }

    /// @dev A chain added under the old deployer and not yet live is re-keyed in the same batch, so
    ///      its prediction moves with the rotation and stays pending.
    function test_aPendingPairIsRekeyedWithTheRotation() public {
        skipUnderCoverage();
        Plan memory p = _plan();
        ChainEntry memory chain = p.chains[1];
        bytes32 lz = keccak256(bytes(LZ));
        uint256 other = p.chains[2].chainId;
        PendingPair[] memory pending = new PendingPair[](1);
        pending[0] = PendingPair({chainId: other, provider: LZ});

        vm.chainId(chain.chainId);
        ChainContracts memory c = ChainDeploy.deploy(p.g);
        vm.startPrank(address(c.timelock));
        bytes32 key = c.registry.addChainKey(Erc7930.encodeEvmChain(other), Provenance.Predetermined);
        c.registry.addProviderOnChain(key, lz, p.g.deployer);
        vm.stopPrank();
        Call memory schedule = GovernancePlan.scheduleRotation(p, NEW, pending);
        Tx memory execute = GovernancePlan.executeRotation(p, NEW, pending);
        vm.prank(GovernancePlan.governor(p, p.g.proposers[0]));
        (bool ok,) = schedule.target.call(schedule.data);
        assertTrue(ok);
        vm.warp(block.timestamp + p.g.timelockDelay);
        (bool done,) = execute.to.call(execute.data);
        assertTrue(done);

        assertEq(c.registry.currentDeployer(), NEW);
        assertEq(c.registry.deployedBy(key, lz), NEW, "re-keyed");
        assertTrue(c.registry.statusOf(key, lz) == Status.Pending);
    }

    /// @dev Naming a live pair fails the whole batch, so the rotation does not half apply.
    function test_aLivePairInTheBatchFailsItWhole() public {
        skipUnderCoverage();
        Plan memory p = _plan();
        PendingPair[] memory pending = new PendingPair[](1);
        pending[0] = PendingPair({chainId: p.g.home.chainId, provider: LZ});

        vm.chainId(p.chains[1].chainId);
        ChainContracts memory c = ChainDeploy.deploy(p.g);
        Call memory schedule = GovernancePlan.scheduleRotation(p, NEW, pending);
        Tx memory execute = GovernancePlan.executeRotation(p, NEW, pending);
        vm.prank(GovernancePlan.governor(p, p.g.proposers[0]));
        (bool ok,) = schedule.target.call(schedule.data);
        assertTrue(ok);
        vm.warp(block.timestamp + p.g.timelockDelay);
        (bool done,) = execute.to.call(execute.data);

        assertFalse(done, "the home's pair is live");
        assertEq(c.registry.currentDeployer(), p.g.deployer, "nothing applied");
    }

    /* ================================== the files ================================= */

    function test_theScriptWritesTheSameBatchesEveryRun() public {
        Plan memory p = _plan();
        RotateDeployer script = _script("same", NEW, "", "");
        string memory dir = string.concat(vm.projectRoot(), "/out/rotation/test/same");
        script.run();
        // forge-lint: disable-next-line(unsafe-cheatcode) reads the batch the script wrote
        string memory first = vm.readFile(string.concat(dir, "/2-schedule-remote.json"));
        script.run();
        // forge-lint: disable-next-line(unsafe-cheatcode) reads the batch the script wrote
        assertEq(vm.readFile(string.concat(dir, "/2-schedule-remote.json")), first);

        Tx[] memory remote = GovernancePlan.rotateRemote(p, NEW, _none());
        assertEq(remote.length, p.chains.length - 1, "one message to every other chain");
        assertEq(vm.parseJsonBytes(first, ".transactions[0].data"), remote[0].data);
        assertEq(vm.parseJsonAddress(first, ".meta.createdFromSafeAddress"), p.g.owner);

        // forge-lint: disable-next-line(unsafe-cheatcode) reads the batch the script wrote
        string memory home = vm.readFile(string.concat(dir, "/1-schedule-home.json"));
        assertEq(vm.parseJsonUint(home, ".chainId"), p.g.home.chainId);
        for (uint256 i; i < p.chains.length; ++i) {
            // forge-lint: disable-next-line(unsafe-cheatcode) reads the batch the script wrote
            string memory execute = vm.readFile(string.concat(dir, "/3-execute-", p.chains[i].name, ".json"));
            assertEq(vm.parseJsonUint(execute, ".chainId"), p.chains[i].chainId);
        }
    }

    function test_thePendingPairsAreNamedByChainAndProvider() public {
        Plan memory p = _plan();
        RotateDeployer script = _script("pending", NEW, p.chains[2].name, LZ);
        script.run();

        PendingPair[] memory pending = new PendingPair[](1);
        pending[0] = PendingPair({chainId: p.chains[2].chainId, provider: LZ});
        Tx memory execute = GovernancePlan.executeRotation(p, NEW, pending);
        string memory file =
            string.concat(vm.projectRoot(), "/out/rotation/test/pending/3-execute-", p.chains[0].name, ".json");
        // forge-lint: disable-next-line(unsafe-cheatcode) reads the batch the script wrote
        assertEq(vm.parseJsonBytes(vm.readFile(file), ".transactions[0].data"), execute.data);
    }

    /* ================================== refusals ================================== */

    function _expect(string memory what) internal {
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, what));
    }

    function test_noDeployerOrTheCurrentOneIsRefused() public {
        Plan memory p = _plan();
        RotateDeployer none = _script("none", address(0), "", "");
        RotateDeployer same = _script("current", p.g.deployer, "", "");

        _expect("NEW_DEPLOYER is set");
        none.run();
        _expect("NEW_DEPLOYER is not governance.toml's deployed_by");
        same.run();
    }

    function test_aPendingListThatDoesNotPairUpIsRefused() public {
        Plan memory p = _plan();
        RotateDeployer script = _script("unpaired", NEW, p.chains[1].name, "");
        _expect("PENDING_CHAINS and PENDING_PROVIDERS pair up");
        script.run();
    }

    function test_anUnknownChainOrProviderIsRefused() public {
        Plan memory p = _plan();
        RotateDeployer unknownChain = _script("nochain", NEW, "nowhere", LZ);
        RotateDeployer unknownProvider = _script("noprovider", NEW, p.chains[1].name, "nobody");

        _expect("a pending pair names a parity chain in chains.toml");
        unknownChain.run();
        _expect("governance.toml: provider has a record");
        unknownProvider.run();
    }
}
