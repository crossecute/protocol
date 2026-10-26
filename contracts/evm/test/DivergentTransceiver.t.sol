// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {TransceiverConfig, TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {TransceiverCore} from "src/messaging/transceiver/TransceiverCore.sol";
import {CrossConduits} from "src/conduit/CrossConduits.sol";
import {
    ZkSyncTransceiver,
    TronTransceiver,
    DivergentTransceiver,
    ZkSyncTransceiverExtension,
    TronTransceiverExtension
} from "src/messaging/transceiver/DivergentTransceiver.sol";
import {DivergentConduits} from "src/messaging/transceiver/DivergentConduits.sol";
import {unseeded} from "test/RegistrySeed.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {SymHarness, Rcv, RecordingTransmitter} from "test/Transceiver.t.sol";
import {transceiverConfig, ext} from "test/Harness.sol";

contract ZkSym is ZkSyncTransceiver, SymHarness {
    function initialize(TransceiverConfig memory c, bytes32 hash) external initializer {
        __DivergentTransceiver_init(c, hash);
    }

    function _newExtension() internal override returns (address) {
        return address(new ZkSyncTransceiverExtension());
    }

    function crossProxyInitCode() external view returns (address) {
        return _crossProxyInitCode;
    }

    /// @dev The overrides below only name both bases, as Solidity requires where each supplies
    ///      an implementation; `super` resolves by linearization to the one that does the work.
    function _parityAddress(bytes32 chainKey)
        internal
        view
        override(TransceiverCore, DivergentTransceiver)
        returns (address)
    {
        return super._parityAddress(chainKey);
    }

    function _predictCrossConduit(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        override(TransceiverCore, ZkSyncTransceiver)
        returns (address)
    {
        return super._predictCrossConduit(owner, salt, homeChainKey);
    }

    function _deployConduit(bytes32 salt) internal override(TransceiverBase, ZkSyncTransceiver) returns (address) {
        return super._deployConduit(salt);
    }

    function _storeCrossProxyInitCode() internal override(TransceiverBase, ZkSyncTransceiver) returns (address) {
        return super._storeCrossProxyInitCode();
    }
}

contract TronSym is TronTransceiver, SymHarness {
    function initialize(TransceiverConfig memory c, bytes32 hash) external initializer {
        __DivergentTransceiver_init(c, hash);
    }

    function _newExtension() internal override returns (address) {
        return address(new TronTransceiverExtension());
    }

    function crossProxyInitCode() external view returns (address) {
        return _crossProxyInitCode;
    }

    /// @dev The overrides below only name both bases, as Solidity requires where each supplies
    ///      an implementation; `super` resolves by linearization to the one that does the work.
    function _parityAddress(bytes32 chainKey)
        internal
        view
        override(TransceiverCore, DivergentTransceiver)
        returns (address)
    {
        return super._parityAddress(chainKey);
    }

    function _predictCrossConduit(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        override(TransceiverCore, TronTransceiver)
        returns (address)
    {
        return super._predictCrossConduit(owner, salt, homeChainKey);
    }
}

/// @dev The zkSync and Tron transceivers. Forge runs Ethereum's EVM, so these pin that each
///      derives with its chain's formula, that the formula reaches the owner and the default
///      counterpart, and that conduit creation fails closed here rather than misdeploying.
contract DivergentTransceiverTest is Test {
    bytes32 constant HASH = keccak256("zksolc CrossProxy");
    bytes32 constant SALT = keccak256("account");
    bytes32 constant PROVIDER_SALT = keccak256("provider");
    /// @dev Whoever deployed the provider's transceivers on parity chains.
    address constant DEPLOYED_BY = address(0xDE91);
    address msig = address(0x5165);
    address alice = address(0xA11CE);

    function _config() internal returns (TransceiverConfig memory) {
        return transceiverConfig(msig, address(new RecordingTransmitter()), address(new Rcv()), address(0x7EA5));
    }

    function _zk() internal returns (ZkSym t) {
        t = new ZkSym();
        t.initialize(_config(), HASH);
    }

    /* ================================= derivation ================================= */

    function testFuzz_zkSyncDerivesTheEraWay(address o, bytes32 salt, bytes32 home) public {
        ZkSym t = _zk();
        assertEq(
            ext(address(t)).predictCrossConduit(o, salt, home),
            AddressDerive.zksyncCreate2(address(t), ext(address(t)).conduitSalt(o, salt, home), HASH, keccak256(""))
        );
    }

    function testFuzz_tronDerivesTheTronWay(address o, bytes32 salt, bytes32 home) public {
        TronSym t = new TronSym();
        t.initialize(_config(), HASH);
        assertEq(
            ext(address(t)).predictCrossConduit(o, salt, home),
            AddressDerive.tronCreate2(address(t), ext(address(t)).conduitSalt(o, salt, home), HASH)
        );
    }

    /// @dev The owner is derived with this chain's formula, which is why the bytecode hash is
    ///      set before the base initializer runs.
    function test_theOwnerIsDerivedTheEraWay() public {
        ZkSym t = _zk();
        address viaEra = ext(address(t)).predictCrossConduit(msig, bytes32(0), ChainKey.forEvm(1));
        address viaEthereum = Create2.computeAddress(
            ext(address(t)).conduitSalt(msig, bytes32(0), ChainKey.forEvm(1)),
            t.CROSS_PROXY_INIT_CODE_HASH(),
            address(t)
        );

        assertEq(t.owner(), viaEra);
        assertTrue(viaEra != viaEthereum, "not the address Ethereum's formula gives");
    }

    /// @dev These chains always report, whatever the caller passed.
    function test_itAlwaysDiverges() public {
        assertTrue(ext(address(_zk())).addressesDiverge());
    }

    /// @dev EraVM cannot deploy raw initcode, so the zkSync implementation's constructor must
    ///      not try; Tron deploys from the stored copy as a parity chain does.
    function test_onlyZkSyncStoresNoInitCode() public {
        assertEq(new ZkSym().crossProxyInitCode(), address(0));
        assertTrue(new TronSym().crossProxyInitCode().code.length != 0);
    }

    function test_aZeroBytecodeHashIsRefused() public {
        ZkSym t = new ZkSym();
        TransceiverConfig memory c = _config();
        vm.expectRevert(DivergentConduits.ZeroConduitBytecodeHash.selector);
        t.initialize(c, bytes32(0));
    }

    /// @dev On Forge's EVM the deployment lands at Ethereum's address and the guard refuses.
    function test_conduitCreationFailsClosedOnAnEthereumEvm() public {
        ZkSym t = _zk();
        address predicted = ext(address(t)).predictCrossConduit(alice, SALT, t.localChainKey());

        vm.prank(alice);
        vm.expectPartialRevert(CrossConduits.ConduitAddressMismatch.selector);
        t.createTransmitter(SALT);
        assertEq(predicted.code.length, 0);
    }

    /* ============================ the default counterpart ========================== */

    /// @dev A transmitter homed on zkSync records this as its receiver on a parity chain: the
    ///      conduit's address there under Ethereum's formula and the recorded solc initcode
    ///      hash, not its own Era address nor this compiler's hash (#30). Forge compiles with
    ///      solc, so a distinct recorded hash stands in for the zksolc/solc difference.
    function test_aZkSyncHomePredictsItsReceiversTheEthereumWay() public {
        ZkSym t = _zk();
        ChainRegistry registry = new ChainRegistry(address(this), unseeded());
        bytes32 provider = registry.addMessageProvider("test");
        bytes32 base = registry.addChainKey(Erc7930.encodeEvmChain(8453), Provenance.Predetermined);
        vm.prank(t.owner());
        ext(address(t)).setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Unique);

        vm.expectRevert(ChainRegistry.NoProviderDeployment.selector);
        t.predictReceiver(base, alice, SALT);

        bytes32 solcHash = keccak256("solc CrossProxy");
        registry.setProviderDeployment(provider, DEPLOYED_BY, PROVIDER_SALT, solcHash);

        address there = registry.predictTransceiver(base, provider);
        address receiver =
            Create2.computeAddress(ext(address(t)).conduitSalt(alice, SALT, t.localChainKey()), solcHash, there);

        assertEq(t.predictReceiver(base, alice, SALT), abi.encodePacked(receiver));
        assertTrue(
            receiver != ext(address(t)).predictCrossConduit(alice, SALT, t.localChainKey()), "not the Era address"
        );
    }

    /// @dev This transceiver is not at its provider's address on parity chains, so the
    ///      default counterpart there is the registry's prediction, and nothing until the
    ///      provider's deployment is recorded.
    function test_theDefaultCounterpartIsTheProvidersParityAddress() public {
        ZkSym t = _zk();
        ChainRegistry registry = new ChainRegistry(address(this), unseeded());
        bytes32 provider = registry.addMessageProvider("test");
        bytes32 base = registry.addChainKey(Erc7930.encodeEvmChain(8453), Provenance.Predetermined);

        vm.prank(t.owner());
        ext(address(t)).setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Unique);

        vm.expectRevert(ChainRegistry.NoProviderDeployment.selector);
        t.counterpartOn(base);

        registry.setProviderDeployment(provider, DEPLOYED_BY, PROVIDER_SALT, t.CROSS_PROXY_INIT_CODE_HASH());
        address expected = registry.predictTransceiver(base, provider);
        assertEq(t.counterpartOn(base), abi.encodePacked(expected));
        assertTrue(expected != address(t), "not this contract's own address");
    }
}
