// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {Call} from "src/messaging/Call.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {IProviderIdTable} from "src/protocols/ProviderChainId.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {DeployCheck} from "script/deploy/CrossProxyDeploy.sol";
import {ChainConfig, ChainEntry} from "script/deploy/ChainConfig.sol";
import {GovernanceConfig, ChainContracts, ChainDeploy} from "script/deploy/ChainDeploy.sol";
import {Plan, Tx, GovernancePlan} from "script/deploy/GovernancePlan.sol";
import {GovernancePayloads} from "script/GovernancePayloads.s.sol";
import {DeployProvider} from "script/DeployProvider.s.sol";
import {testGovernanceFile, skipUnderCoverage} from "test/deploy/TestGovernance.sol";
import {
    TestDeployLz,
    TestDeployCcip,
    TestDeployHyperlane,
    TestDeployWormhole,
    TestDeployOpStack
} from "test/deploy/ProductionDeploy.t.sol";

contract GovernancePayloadsWithTestConfig is GovernancePayloads {
    function _governanceFile() internal view override returns (string memory) {
        return testGovernanceFile();
    }

    function _outDir() internal view override returns (string memory) {
        return string.concat(vm.projectRoot(), "/out/governance/test");
    }
}

/// @notice The plan, run against step 1 and step 2 as their scripts deploy them, one chain at a
///         time: every transaction succeeds in the order the files are numbered, and leaves every
///         parity chain with the tables `deploy/` describes.
/// @dev Parity chains share every address, so each chain is deployed from a clean state. A
///      bootstrap's and a message's payload is run as the governor's conduit it would arrive at,
///      which is the owner of every transceiver it calls and a proposer on the timelock.
contract GovernancePlanTest is Test {
    function _plan() internal view returns (Plan memory) {
        return GovernancePlan.load(ChainConfig.defaultDir(), testGovernanceFile());
    }

    /// @dev The same values `ProductionDeploy.t.sol` sets, since the environment is shared.
    function setUp() public {
        _setEnv("MIN_COUNTERPART_PROVENANCE", "1");
        _setEnv("LZ_ENDPOINT", vm.toString(address(0xE0001)));
        _setEnv("CCIP_ROUTER", vm.toString(address(0xE0002)));
        _setEnv("HYPERLANE_MAILBOX", vm.toString(address(0xE0003)));
        _setEnv("WORMHOLE_CORE", vm.toString(address(0xE0004)));
        _setEnv("WORMHOLE_EXECUTOR", vm.toString(address(0xE0005)));
    }

    function _setEnv(string memory name, string memory value) internal {
        // forge-lint: disable-next-line(unsafe-cheatcode) the scripts' inputs are environment variables
        vm.setEnv(name, value);
    }

    /// @notice Steps 1 and 2 on `chain`, with every provider's endpoint mocked.
    function _deployChain(Plan memory p, ChainEntry memory chain) internal returns (ChainContracts memory c) {
        vm.chainId(chain.chainId);
        c = ChainDeploy.deploy(p.g);
        deployCodeTo("MockLzEndpoint.sol:MockLzEndpoint", address(0xE0001));
        deployCodeTo("MockCcipRouter.sol:MockCcipRouter", address(0xE0002));
        deployCodeTo("MockHyperlaneMailbox.sol:MockHyperlaneMailbox", address(0xE0003));
        uint16 wormholeChain = uint16(ChainConfig.providerId(p.dir, p.all, "wormhole", chain));
        deployCodeTo("MockWormholeCore.sol:MockWormholeCore", abi.encode(wormholeChain), address(0xE0004));
        deployCodeTo("MockExecutor.sol:MockExecutor", abi.encode(wormholeChain), address(0xE0005));
        for (uint256 i; i < p.chains.length; ++i) {
            uint256 m = GovernancePlan.idFor(p, "op-stack-l1-l2", chain, p.chains[i]);
            if (m != 0) deployCodeTo("MockCrossDomainMessenger.sol:MockCrossDomainMessenger", address(uint160(m)));
        }

        string[5] memory names = ["layerzero", "ccip", "hyperlane", "wormhole", "op-stack-l1-l2"];
        DeployProvider[5] memory scripts = [
            DeployProvider(new TestDeployLz()),
            new TestDeployCcip(),
            new TestDeployHyperlane(),
            new TestDeployWormhole(),
            new TestDeployOpStack()
        ];
        for (uint256 i; i < names.length; ++i) {
            if (GovernancePlan.isOn(p, names[i], chain)) scripts[i].run();
        }
    }

    function _submit(address from, Tx[] memory txs) internal {
        for (uint256 i; i < txs.length; ++i) {
            _call(from, txs[i].to, txs[i].value, txs[i].data);
        }
    }

    function _call(address from, address to, uint256 value, bytes memory data) internal returns (uint256 used) {
        vm.prank(from);
        uint256 before = gasleft();
        (bool ok, bytes memory reason) = to.call{value: value}(data);
        used = before - gasleft();
        if (!ok) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    /// @notice Run a payload as `conduit` would on arrival, holding each call to its budget.
    function _arrive(Plan memory p, ChainEntry memory chain, address conduit, Call[] memory calls) internal {
        uint256 scheduleBudget = GovernancePlan.scheduleGas(p, chain);
        for (uint256 i; i < calls.length; ++i) {
            uint256 used = _call(conduit, calls[i].target, calls[i].value, calls[i].data);
            bool isSchedule = calls[i].target == address(ChainDeploy.predict(p.g).timelock);
            assertLe(used * 11 / 10, isSchedule ? scheduleBudget : GovernancePlan.CALL_GAS, "a call fits its budget");
        }
    }

    /* ================================== the home ================================ */

    function test_theHomeIsPreparedAndBootstrapsEveryOtherChain() public {
        skipUnderCoverage();
        Plan memory p = _plan();
        ChainContracts memory c = _deployChain(p, p.g.home);
        _submit(p.g.owner, GovernancePlan.prepareHome(p));

        Tx memory execute = GovernancePlan.executeRegistry(p, p.g.home);
        vm.expectRevert();
        _call(address(0xA11CE), execute.to, 0, execute.data);
        vm.warp(block.timestamp + p.g.timelockDelay);
        _call(address(0xA11CE), execute.to, 0, execute.data);
        _assertConfigured(p, c, p.g.home, false);

        for (uint256 i; i < p.g.providers.length; ++i) {
            vm.deal(GovernancePlan.governor(p, p.g.providers[i].name), 100 ether);
        }
        _submit(p.g.owner, GovernancePlan.bootstrap(p));
        _assertConfigured(p, c, p.g.home, true);
        for (uint256 i; i < p.chains.length; ++i) {
            if (p.chains[i].chainId == p.g.home.chainId) continue;
            for (uint256 j; j < p.g.providers.length; ++j) {
                string memory name = p.g.providers[j].name;
                if (GovernancePlan.idFor(p, name, p.g.home, p.chains[i]) == 0) continue;
                address conduit = GovernancePlan.governor(p, name);
                assertTrue(TransmitterBase(payable(conduit)).isBootstrappedOn(p.chains[i].chainId), "bootstrapped");
            }
        }
    }

    /* ============================== every other chain =========================== */

    function test_everyOtherChainIsConfiguredByItsBootstrapAndConnect() public {
        skipUnderCoverage();
        Plan memory p = _plan();
        Tx[] memory bootstraps = GovernancePlan.bootstrap(p);
        Tx[] memory connects = GovernancePlan.connect(p);
        uint256 clean = vm.snapshotState();
        for (uint256 i; i < p.chains.length; ++i) {
            ChainEntry memory x = p.chains[i];
            if (x.chainId == p.g.home.chainId) continue;
            vm.revertToState(clean);
            ChainContracts memory c = _deployChain(p, x);

            for (uint256 j; j < bootstraps.length; ++j) {
                if (bytes4(bootstraps[j].data) != TransmitterBase.bootstrap.selector) continue;
                (uint256 chainId, Call[] memory calls,) =
                    abi.decode(_args(bootstraps[j].data), (uint256, Call[], bytes[]));
                if (chainId == x.chainId) _arrive(p, x, bootstraps[j].to, calls);
            }
            Tx memory execute = GovernancePlan.executeRegistry(p, x);
            vm.warp(block.timestamp + p.g.timelockDelay);
            _call(address(0xA11CE), execute.to, 0, execute.data);
            for (uint256 j; j < connects.length; ++j) {
                (bytes memory recipient, bytes memory payload,) =
                    abi.decode(_args(connects[j].data), (bytes, bytes, bytes[]));
                if (ChainKey.fromIdentifier(recipient) == ChainKey.forEvm(x.chainId)) {
                    _arrive(p, x, connects[j].to, abi.decode(payload, (Call[])));
                }
            }
            _assertConfigured(p, c, x, true);
        }
    }

    /// @notice `local`'s registry grades every parity chain as `deploy/` does and names each
    ///         provider's transceiver, and each transceiver has a route and id for every chain it
    ///         connects to, and, if `peers`, its LayerZero peer.
    function _assertConfigured(Plan memory p, ChainContracts memory c, ChainEntry memory local, bool peers)
        internal
        view
    {
        for (uint256 i; i < p.chains.length; ++i) {
            bytes32 key = ChainKey.forEvm(p.chains[i].chainId);
            assertEq(uint8(c.registry.provenanceFor(key)), uint8(ChainConfig.gradeOf(local, p.chains[i])), "grade");
        }
        assertFalse(c.registry.hasChainKey(ChainKey.forEvm(324)), "zkSync is not configured");
        for (uint256 j; j < p.g.providers.length; ++j) {
            string memory name = p.g.providers[j].name;
            if (!GovernancePlan.isOn(p, name, local)) continue;
            address t = GovernancePlan.transceiver(p, name);
            assertEq(c.registry.localTransceiver(keccak256(bytes(name))), t, "local transceiver");
            for (uint256 i; i < p.chains.length; ++i) {
                uint256 id = GovernancePlan.idFor(p, name, local, p.chains[i]);
                if (id == 0) continue;
                bytes32 key = ChainKey.forEvm(p.chains[i].chainId);
                assertTrue(OutboundBase(t).hasRoute(key), "route");
                assertEq(IProviderIdTable(t).providerIdFor(key), id, "provider id");
                if (peers && keccak256(bytes(name)) == keccak256("layerzero")) {
                    assertEq(IOAppCore(t).peers(uint32(id)), bytes32(uint256(uint160(t))), "peer");
                }
            }
        }
    }

    /* =================================== the files ============================== */

    function test_theScriptWritesTheSameBatchesEveryRun() public {
        Plan memory p = _plan();
        GovernancePayloads script = new GovernancePayloadsWithTestConfig();
        string memory file = string.concat(vm.projectRoot(), "/out/governance/test/3-bootstrap.json");
        script.run();
        // forge-lint: disable-next-line(unsafe-cheatcode) reads the batch the script wrote
        string memory first = vm.readFile(file);
        script.run();
        // forge-lint: disable-next-line(unsafe-cheatcode) reads the batch the script wrote
        assertEq(vm.readFile(file), first);

        Tx[] memory txs = GovernancePlan.bootstrap(p);
        assertEq(vm.parseJsonUint(first, ".chainId"), p.g.home.chainId);
        assertEq(vm.parseJsonAddress(first, ".meta.createdFromSafeAddress"), p.g.owner);
        assertEq(vm.parseJsonKeys(first, string.concat(".transactions[", vm.toString(txs.length - 1), "]")).length, 4);
        assertEq(vm.parseJsonBytes(first, ".transactions[0].data"), txs[0].data);
    }

    function test_theProductionFileIsRefusedUntilSet() public {
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "governance.toml: owner is set"));
        this.loadProduction();
    }

    function loadProduction() external view {
        GovernancePlan.load(ChainConfig.defaultDir(), GovernanceConfig.defaultFile());
    }

    /// @dev `op-stack-l1-l2` reaches only the OP Stack chains from Ethereum, so Arbitrum would get
    ///      neither its registry scheduled nor that proposer.
    function test_aProposerThatDoesNotReachEveryChainIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "each proposer reaches every chain"));
        this.load(string.concat(vm.projectRoot(), "/test/deploy/config/governance-unreaching-proposer.toml"));
    }

    function load(string memory file) external view {
        GovernancePlan.load(ChainConfig.defaultDir(), file);
    }

    function _args(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }
}
