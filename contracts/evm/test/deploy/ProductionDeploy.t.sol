// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CrossProxy} from "src/account/CrossProxy.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {ChainRegistry, RegistrySeed, ProviderSeed} from "src/registry/ChainRegistry.sol";
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

/// @notice What every production-script test shares: the environment, a chain
///         `deploy/chains.toml` configures, and a registry seeded with every provider's record.
/// @dev `vm.setEnv` is process-wide and tests run in parallel, so every test sets the same
///      values: mocks and the registry sit at fixed addresses, and the registry records every
///      provider.
abstract contract ProductionDeploySpecBase is Test {
    address internal constant REGISTRY = address(0x5EED0000);
    address internal constant BROADCASTER = DEFAULT_SENDER;
    uint256 internal constant HOME_CHAIN_ID = 1;
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
        _setEnv("CHAIN_REGISTRY", vm.toString(REGISTRY));
        _setEnv("TREASURY", vm.toString(address(0x7EA5)));
        _setEnv("GOVERNOR_OWNER", vm.toString(address(0x5165)));
        _setEnv("GOVERNOR_HOME_CHAIN_ID", vm.toString(HOME_CHAIN_ID));
        _setEnv("MIN_COUNTERPART_PROVENANCE", "1");
        _setUpProvider();
    }

    /// @notice The registry at `REGISTRY`, homed on `HOME_CHAIN_ID`, recording every provider
    ///         as deployed by `deployedBy`.
    function _seedRegistry(address deployedBy) internal {
        _seedRegistry(deployedBy, Provenance.Predetermined);
    }

    function _seedRegistry(address deployedBy, Provenance homeGrade) internal {
        _seedRegistry(deployedBy, homeGrade, HOME_CHAIN_ID);
    }

    function _seedRegistry(address deployedBy, Provenance homeGrade, uint256 homeChainId) internal {
        string[6] memory names = ["layerzero", "ccip", "hyperlane", "wormhole", "op-stack-l1-l2", "op-stack-l2-l2"];
        ProviderSeed[] memory providers = new ProviderSeed[](6);
        for (uint256 i; i < 6; ++i) {
            providers[i] = ProviderSeed(
                names[i], deployedBy, keccak256(bytes(names[i])), keccak256(type(CrossProxy).creationCode)
            );
        }
        deployCodeTo(
            "ChainRegistry.sol:ChainRegistry",
            abi.encode(
                address(this),
                RegistrySeed({
                    governorHome: Erc7930.encodeEvmChain(homeChainId),
                    governorHomeGrade: homeGrade,
                    providers: providers
                })
            ),
            REGISTRY
        );
    }
}

/// @notice Each production script, run as a broadcast against mocks at fixed addresses, lands its
///         transceiver where the registry predicts. Each provider's governor home id is read
///         from `deploy/providers/`.
abstract contract ProductionDeploySpec is ProductionDeploySpecBase {
    function _script() internal virtual returns (DeployProvider);

    function _providerName() internal pure virtual returns (string memory);

    function test_theTransceiverLandsWhereTheRegistryPredicts() public {
        _seedRegistry(BROADCASTER);
        address t = _script().run();
        bytes32 provider = keccak256(bytes(_providerName()));
        assertEq(t, ChainRegistry(REGISTRY).predictTransceiver(ChainKey.forEvm(HOME_CHAIN_ID), provider));
        assertEq(TransceiverBase(payable(t)).messageProvider(), provider);
    }

    /// @dev A grade is write-once, so a registry that disagrees with deploy/chains.toml is
    ///      refused before anything is deployed against it.
    function test_aRegistryGradingAChainOtherwiseIsRefused() public {
        _seedRegistry(BROADCASTER, Provenance.Unique);
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
        _seedRegistry(address(0xBAD));
        DeployProvider script = _script();
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "the broadcaster is the recorded deployedBy"));
        script.run();
    }
}

contract DeployLzTest is ProductionDeploySpec {
    function _script() internal override returns (DeployProvider) {
        return new DeployLz();
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
        return new DeployCcip();
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
        return new DeployHyperlane();
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
        return new DeployWormhole();
    }

    function _providerName() internal pure override returns (string memory) {
        return "wormhole";
    }

    function _setUpProvider() internal override {
        deployCodeTo("MockWormholeCore.sol:MockWormholeCore", abi.encode(uint16(2)), address(0xE0004));
        deployCodeTo("MockExecutorQuoterRouter.sol:MockExecutorQuoterRouter", address(0xE0005));
        _setEnv("WORMHOLE_CORE", vm.toString(address(0xE0004)));
        _setEnv("WORMHOLE_EXECUTOR_ROUTER", vm.toString(address(0xE0005)));
        _setEnv("WORMHOLE_QUOTER", vm.toString(address(0x0907)));
    }
}

contract DeployOpStackTest is ProductionDeploySpec {
    function _script() internal override returns (DeployProvider) {
        return new DeployOpStack();
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
        _seedRegistry(BROADCASTER);
        DeployOpStackInterop script = new DeployOpStackInterop();
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "this chain runs op-stack-l2-l2"));
        script.run();
    }
}
