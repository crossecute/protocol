// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {RegistrySeed} from "src/registry/ChainRegistry.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {DeployCheck} from "script/deploy/CrossProxyDeploy.sol";
import {DeployProvider} from "script/DeployProvider.s.sol";
import {DeployLz} from "script/DeployLz.s.sol";
import {DeployCcip} from "script/DeployCcip.s.sol";
import {DeployHyperlane} from "script/DeployHyperlane.s.sol";
import {DeployWormhole} from "script/DeployWormhole.s.sol";
import {DeployOpStack} from "script/DeployOpStack.s.sol";
import {DeployOpStackInterop} from "script/DeployOpStackInterop.s.sol";
import {ext} from "test/Harness.sol";
import {Governance, ChainContracts, ChainDeploy} from "script/deploy/ChainDeploy.sol";
import {testGovernanceFile, testGovernance, skipUnderCoverage} from "test/deploy/TestGovernance.sol";

/// @notice What every production-script test shares: the environment, a chain
///         `deploy/chains.toml` configures, and step 1's contracts from the test governance file.
/// @dev `vm.setEnv` is process-wide and tests run in parallel, so every test sets the same
///      values: mocks sit at fixed addresses.
abstract contract ProductionDeploySpecBase is Test {
    address internal constant BROADCASTER = DEFAULT_SENDER;
    /// @dev Base, a parity chain in deploy/chains.toml.
    uint256 internal constant LOCAL_CHAIN_ID = 8453;

    /// @dev Each script reads its production inputs from the environment, which is how a
    ///      broadcast receives them; the values are identical in every test.
    function _setEnv(string memory name, string memory value) internal {
        // forge-lint: disable-next-line(unsafe-cheatcode) the scripts' inputs are environment variables
        vm.setEnv(name, value);
    }

    /// @notice Place the provider's mocks and set its own variables.
    function _setUpProvider() internal virtual {}

    function setUp() public {
        // The scripts deploy only to a chain in deploy/chains.toml.
        vm.chainId(LOCAL_CHAIN_ID);
        _setEnv("MIN_COUNTERPART_PROVENANCE", "1");
        _setUpProvider();
    }

    /// @notice Step 1, as `DeployChain` runs it.
    function _deployStep1() internal returns (ChainContracts memory) {
        return ChainDeploy.deploy(testGovernance());
    }

    /// @notice A registry at step 1's address that disagrees with the governance file: homed on
    ///         `homeChainId` with `homeGrade`, recording every provider as deployed by `deployedBy`.
    function _seedRegistry(address deployedBy, Provenance homeGrade, uint256 homeChainId) internal {
        Governance memory g = testGovernance();
        ChainContracts memory c = ChainDeploy.predict(g);
        RegistrySeed memory s = ChainDeploy.seed(g);
        s.governorHome = Erc7930.encodeEvmChain(homeChainId);
        s.governorHomeGrade = homeGrade;
        for (uint256 i; i < s.providers.length; ++i) {
            s.providers[i].deployedBy = deployedBy;
        }
        deployCodeTo("ChainRegistry.sol:ChainRegistry", abi.encode(address(c.timelock), s), address(c.registry));
    }
}

/// @notice Each production script, run as a broadcast against mocks at fixed addresses, lands its
///         transceiver where the registry predicts. Each provider's governor home id is read
///         from `deploy/providers/`.
abstract contract ProductionDeploySpec is ProductionDeploySpecBase {
    function _script() internal virtual returns (DeployProvider);

    function _providerName() internal pure virtual returns (string memory);

    function test_theTransceiverLandsWhereTheRegistryPredicts() public {
        skipUnderCoverage();
        ChainContracts memory c = _deployStep1();
        address t = _script().run();
        bytes32 provider = keccak256(bytes(_providerName()));
        assertEq(t, c.registry.predictTransceiver(ChainKey.forEvm(testGovernance().home.chainId), provider));
        assertEq(ext(address(TransceiverBase(payable(t)))).messageProvider(), provider);
    }

    /// @dev A grade is write-once, so a registry that disagrees with deploy/chains.toml is
    ///      refused before anything is deployed against it.
    function test_aRegistryGradingAChainOtherwiseIsRefused() public {
        _seedRegistry(BROADCASTER, Provenance.Unique, 1);
        DeployProvider script = _script();
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "registry grades agree with chains.toml"));
        script.run();
    }

    /// @dev A registry seeded with another home has not registered this one, and the deploy
    ///      says so rather than failing inside the initializer.
    function test_aRegistryWithoutTheGovernorsHomeIsRefused() public {
        _seedRegistry(BROADCASTER, Provenance.Predetermined, 10);
        DeployProvider script = _script();
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "the registry has the governor's home"));
        script.run();
    }

    /// @dev A production deployment uses the recorded salt from the recorded caller only.
    function test_aBroadcasterOtherThanTheRecordedOneIsRefused() public {
        _seedRegistry(address(0xBAD), Provenance.Predetermined, 1);
        DeployProvider script = _script();
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "the broadcaster is the recorded deployedBy"));
        script.run();
    }
}

contract DeployLzTest is ProductionDeploySpec {
    function _script() internal override returns (DeployProvider) {
        return new TestDeployLz();
    }

    function _providerName() internal pure override returns (string memory) {
        return "layerzero";
    }

    function _setUpProvider() internal override {
        deployCodeTo("MockLzEndpoint.sol:MockLzEndpoint", address(0xE0001));
        _setEnv("LZ_ENDPOINT", vm.toString(address(0xE0001)));
    }
}

contract DeployCcipTest is ProductionDeploySpec {
    function _script() internal override returns (DeployProvider) {
        return new TestDeployCcip();
    }

    function _providerName() internal pure override returns (string memory) {
        return "ccip";
    }

    function _setUpProvider() internal override {
        deployCodeTo("MockCcipRouter.sol:MockCcipRouter", address(0xE0002));
        _setEnv("CCIP_ROUTER", vm.toString(address(0xE0002)));
    }
}

contract DeployHyperlaneTest is ProductionDeploySpec {
    function _script() internal override returns (DeployProvider) {
        return new TestDeployHyperlane();
    }

    function _providerName() internal pure override returns (string memory) {
        return "hyperlane";
    }

    function _setUpProvider() internal override {
        deployCodeTo("MockHyperlaneMailbox.sol:MockHyperlaneMailbox", address(0xE0003));
        _setEnv("HYPERLANE_MAILBOX", vm.toString(address(0xE0003)));
    }
}

contract DeployWormholeTest is ProductionDeploySpec {
    function _script() internal override returns (DeployProvider) {
        return new TestDeployWormhole();
    }

    function _providerName() internal pure override returns (string memory) {
        return "wormhole";
    }

    function _setUpProvider() internal override {
        deployCodeTo("MockWormholeCore.sol:MockWormholeCore", abi.encode(uint16(2)), address(0xE0004));
        deployCodeTo("MockExecutor.sol:MockExecutor", abi.encode(uint16(2)), address(0xE0005));
        _setEnv("WORMHOLE_CORE", vm.toString(address(0xE0004)));
        _setEnv("WORMHOLE_EXECUTOR", vm.toString(address(0xE0005)));
    }
}

contract DeployOpStackTest is ProductionDeploySpec {
    function _script() internal override returns (DeployProvider) {
        return new TestDeployOpStack();
    }

    function _providerName() internal pure override returns (string memory) {
        return "op-stack-l1-l2";
    }

    /// @dev No inputs of its own: on Base, the governor home (Ethereum) is reached through the
    ///      predeploy named in deploy/.
    function _setUpProvider() internal override {}
}

/// @notice `op-stack-l2-l2` waits for interop: its configuration lists no chain yet, so the
///         production script refuses every one, even with the predeploy in place.
contract DeployOpStackInteropTest is ProductionDeploySpecBase {
    function test_noChainRunsInteropYet() public {
        deployCodeTo(
            "MockL2ToL2CrossDomainMessenger.sol:MockL2ToL2CrossDomainMessenger",
            0x4200000000000000000000000000000000000023
        );
        _deployStep1();
        DeployOpStackInterop script = new TestDeployOpStackInterop();
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "this chain runs op-stack-l2-l2"));
        script.run();
    }
}

/// @dev Production's file is not ready to deploy until its addresses are decided.
contract ProductionGovernanceFileTest is ProductionDeploySpecBase {
    function test_theProductionFileRefusesItsUnsetOwner() public {
        DeployCcip script = new DeployCcip();
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "governance.toml: owner is set"));
        script.run();
    }
}

contract TestDeployLz is DeployLz {
    function _governanceFile() internal view override returns (string memory) {
        return testGovernanceFile();
    }
}

contract TestDeployCcip is DeployCcip {
    function _governanceFile() internal view override returns (string memory) {
        return testGovernanceFile();
    }
}

contract TestDeployHyperlane is DeployHyperlane {
    function _governanceFile() internal view override returns (string memory) {
        return testGovernanceFile();
    }
}

contract TestDeployWormhole is DeployWormhole {
    function _governanceFile() internal view override returns (string memory) {
        return testGovernanceFile();
    }
}

contract TestDeployOpStack is DeployOpStack {
    function _governanceFile() internal view override returns (string memory) {
        return testGovernanceFile();
    }
}

contract TestDeployOpStackInterop is DeployOpStackInterop {
    function _governanceFile() internal view override returns (string memory) {
        return testGovernanceFile();
    }
}
