// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {unseeded} from "test/RegistrySeed.sol";
import {ChainRegistry, RegistrySeed, ProviderSeed} from "src/registry/ChainRegistry.sol";
import {Status} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {CROSS_PROXY_DEPLOYER, crossProxySalt} from "src/conduit/CrossProxyDeployer.sol";

/// @notice The registry's per-chain deployer: who may add a provider on a chain and under whom,
///         how a chain not yet deployed is re-keyed, and what it takes to become live.
contract RegistryDeployerTest is Test {
    ChainRegistry registry;

    address owner = address(0xA11CE);
    address d1 = address(0xD1);
    address d2 = address(0xD2);
    bytes32 constant SALT = keccak256("provider salt");
    bytes32 constant INIT_CODE_HASH = keccak256("initcode");

    bytes32 provider;
    bytes32 base;
    bytes32 optimism;

    function setUp() public {
        registry = new ChainRegistry(owner, unseeded());
        vm.startPrank(owner);
        provider = registry.addMessageProvider("layerzero");
        base = registry.addChainKey(Erc7930.encodeEvmChain(8453), Provenance.Predetermined);
        optimism = registry.addChainKey(Erc7930.encodeEvmChain(10), Provenance.Predetermined);
        registry.setProviderDeployment(provider, SALT, INIT_CODE_HASH);
        registry.setCurrentDeployer(d1);
        vm.stopPrank();
    }

    function _predicted(address deployer) internal pure returns (address) {
        return AddressDerive.create2(CROSS_PROXY_DEPLOYER, crossProxySalt(deployer, SALT), INIT_CODE_HASH);
    }

    /* ================================== access =================================== */

    function test_onlyTheOwnerChangesWhoDeploysOrWhatIsLive() public {
        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this));

        vm.expectRevert(notOwner);
        registry.setCurrentDeployer(d2);
        vm.expectRevert(notOwner);
        registry.addProviderOnChain(base, provider, d1);
        vm.expectRevert(notOwner);
        registry.rekeyPending(base, provider, d2);
        vm.expectRevert(notOwner);
        registry.markLive(base, provider);
    }

    /* ============================== adding a provider ============================ */

    function test_aProviderIsAddedPendingUnderTheCurrentDeployer() public {
        vm.prank(owner);
        registry.addProviderOnChain(base, provider, d1);

        assertEq(registry.deployedBy(base, provider), d1);
        assertTrue(registry.statusOf(base, provider) == Status.Pending);
        assertFalse(registry.isLive(base, provider), "pending is not live");
        assertEq(registry.predictTransceiver(base, provider), _predicted(d1));
    }

    function test_aDeployerThatIsNotTheCurrentOneIsRefused() public {
        vm.prank(owner);
        registry.setCurrentDeployer(d2);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ChainRegistry.DeployerMismatch.selector, d1, d2));
        registry.addProviderOnChain(base, provider, d1);
    }

    /// @dev Chain C applies "add" before "rotate" and chain A after it. A names the deployer the
    ///      payload was written for, so A reverts instead of recording the new one for a chain C
    ///      recorded under the old one.
    function test_registriesThatApplyRotateAndAddInOppositeOrdersNeverDisagree() public {
        ChainRegistry early = _registryAt(d1);
        ChainRegistry late = _registryAt(d1);

        vm.startPrank(owner);
        early.addProviderOnChain(base, provider, d1);
        early.setCurrentDeployer(d2);

        late.setCurrentDeployer(d2);
        vm.expectRevert(abi.encodeWithSelector(ChainRegistry.DeployerMismatch.selector, d1, d2));
        late.addProviderOnChain(base, provider, d1);
        vm.stopPrank();

        assertEq(late.deployedBy(base, provider), address(0), "the late registry recorded nothing");
        assertEq(early.deployedBy(base, provider), d1);
    }

    function test_addingIsWriteOnceAndTheSameDeployerAgainIsANoOp() public {
        vm.startPrank(owner);
        registry.addProviderOnChain(base, provider, d1);
        registry.markLive(base, provider);

        registry.setCurrentDeployer(d2);
        registry.addProviderOnChain(base, provider, d1);
        assertTrue(registry.statusOf(base, provider) == Status.Live, "a repeat changes nothing");

        vm.expectRevert(ChainRegistry.AlreadySet.selector);
        registry.addProviderOnChain(base, provider, d2);
        vm.stopPrank();
        assertEq(registry.deployedBy(base, provider), d1);
    }

    function test_aProviderIsAddedOnlyWhereItsInputsExist() public {
        vm.startPrank(owner);
        vm.expectRevert(ChainRegistry.UnknownChainKey.selector);
        registry.addProviderOnChain(keccak256("no chain"), provider, d1);
        vm.expectRevert(ChainRegistry.UnknownMessageProvider.selector);
        registry.addProviderOnChain(base, keccak256("no provider"), d1);

        bytes32 bare = registry.addMessageProvider("bare");
        vm.expectRevert(ChainRegistry.NoProviderDeployment.selector);
        registry.addProviderOnChain(base, bare, d1);

        vm.expectRevert(ChainRegistry.ZeroDeployedBy.selector);
        registry.addProviderOnChain(base, provider, address(0));
        vm.stopPrank();
    }

    function test_aChainTheProviderWasNeverAddedOnIsNotPredicted() public {
        vm.expectRevert(abi.encodeWithSelector(ChainRegistry.NotOnChain.selector, base, provider));
        registry.predictTransceiver(base, provider);
    }

    /* =============================== rotating deployers ========================== */

    /// @dev A chain added before a rotation keeps the address it was added under, and one added
    ///      after it gets the new deployer's.
    function test_rotationMovesNoAddressAlreadyRecorded() public {
        vm.startPrank(owner);
        registry.addProviderOnChain(base, provider, d1);
        registry.setCurrentDeployer(d2);
        registry.addProviderOnChain(optimism, provider, d2);
        vm.stopPrank();

        assertEq(registry.predictTransceiver(base, provider), _predicted(d1));
        assertEq(registry.predictTransceiver(optimism, provider), _predicted(d2));
        assertTrue(_predicted(d1) != _predicted(d2));
    }

    function test_aPendingChainIsRekeyedAndItsPredictionMoves() public {
        vm.startPrank(owner);
        registry.addProviderOnChain(base, provider, d1);
        registry.setCurrentDeployer(d2);
        registry.rekeyPending(base, provider, d2);
        vm.stopPrank();

        assertEq(registry.deployedBy(base, provider), d2);
        assertEq(registry.predictTransceiver(base, provider), _predicted(d2), "the old deployer's address is dropped");
        assertTrue(registry.statusOf(base, provider) == Status.Pending, "and it is still not live");
    }

    function test_aLiveChainCannotBeRekeyed() public {
        vm.startPrank(owner);
        registry.addProviderOnChain(base, provider, d1);
        registry.markLive(base, provider);

        vm.expectRevert(abi.encodeWithSelector(ChainRegistry.NotPending.selector, base, provider));
        registry.rekeyPending(base, provider, d2);
        vm.stopPrank();
        assertEq(registry.predictTransceiver(base, provider), _predicted(d1));
    }

    function test_rekeyingNeedsAPendingEntryAndADeployer() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ChainRegistry.NotPending.selector, base, provider));
        registry.rekeyPending(base, provider, d2);

        registry.addProviderOnChain(base, provider, d1);
        vm.expectRevert(ChainRegistry.ZeroDeployedBy.selector);
        registry.rekeyPending(base, provider, address(0));
        vm.stopPrank();
    }

    /* ==================================== live ================================== */

    function test_liveIsReachedOnlyFromPendingAndOnlyOnce() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ChainRegistry.NotPending.selector, base, provider));
        registry.markLive(base, provider);

        registry.addProviderOnChain(base, provider, d1);
        registry.markLive(base, provider);
        assertTrue(registry.isLive(base, provider));

        vm.expectRevert(abi.encodeWithSelector(ChainRegistry.NotPending.selector, base, provider));
        registry.markLive(base, provider);
        vm.stopPrank();
    }

    function test_liveIsPerProviderAndPerChain() public {
        vm.startPrank(owner);
        bytes32 other = registry.addMessageProvider("ccip");
        registry.setProviderDeployment(other, keccak256("other salt"), INIT_CODE_HASH);
        registry.addProviderOnChain(base, provider, d1);
        registry.addProviderOnChain(base, other, d1);
        registry.addProviderOnChain(optimism, provider, d1);
        registry.markLive(base, provider);
        vm.stopPrank();

        assertTrue(registry.isLive(base, provider));
        assertFalse(registry.isLive(base, other), "another provider on the same chain");
        assertFalse(registry.isLive(optimism, provider), "the same provider on another chain");
    }

    /* ==================================== seed ================================== */

    function test_aSeededHomeIsLiveUnderTheSeedDeployer() public {
        ProviderSeed[] memory providers = new ProviderSeed[](1);
        providers[0] = ProviderSeed("layerzero", SALT, INIT_CODE_HASH);
        bytes memory home = Erc7930.encodeEvmChain(1);
        ChainRegistry seeded = new ChainRegistry(
            owner,
            RegistrySeed({
                governorHome: home, governorHomeGrade: Provenance.Predetermined, deployer: d1, providers: providers
            })
        );
        bytes32 homeKey = keccak256(home);

        assertEq(seeded.currentDeployer(), d1);
        assertEq(seeded.deployedBy(homeKey, provider), d1);
        assertTrue(seeded.isLive(homeKey, provider), "the genesis home needs no mark");
        assertEq(seeded.predictTransceiver(homeKey, provider), _predicted(d1));
    }

    function test_aSeededHomeWithoutADeployerIsRefused() public {
        ProviderSeed[] memory providers = new ProviderSeed[](1);
        providers[0] = ProviderSeed("layerzero", SALT, INIT_CODE_HASH);
        vm.expectRevert(ChainRegistry.ZeroDeployedBy.selector);
        new ChainRegistry(
            owner,
            RegistrySeed({
                governorHome: Erc7930.encodeEvmChain(1),
                governorHomeGrade: Provenance.Predetermined,
                deployer: address(0),
                providers: providers
            })
        );
    }

    /* =================================== helpers ================================ */

    /// @dev A second registry with the same chains and provider, whose current deployer is `d`.
    function _registryAt(address d) internal returns (ChainRegistry r) {
        r = new ChainRegistry(owner, unseeded());
        vm.startPrank(owner);
        r.addMessageProvider("layerzero");
        r.addChainKey(Erc7930.encodeEvmChain(8453), Provenance.Predetermined);
        r.setProviderDeployment(provider, SALT, INIT_CODE_HASH);
        r.setCurrentDeployer(d);
        vm.stopPrank();
    }
}
