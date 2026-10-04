// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {TransceiverConfig, TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {
    ZkSyncTransceiver,
    TronTransceiver,
    DivergentTransceiver
} from "src/messaging/transceiver/DivergentTransceiver.sol";
import {DivergentAccounts} from "src/messaging/transceiver/DivergentAccounts.sol";
import {unseeded} from "test/RegistrySeed.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {SymHarness, Rcv, RecordingTransmitter} from "test/Transceiver.t.sol";

contract ZkSym is ZkSyncTransceiver, SymHarness {
    function initialize(TransceiverConfig memory c, bytes32 hash) external initializer {
        __DivergentTransceiver_init(c, hash);
    }

    /// @dev The overrides below only name both bases, as Solidity requires where each supplies
    ///      an implementation; `super` resolves by linearization to the one that does the work.
    function _parityAddress(bytes32 chainKey)
        internal
        view
        override(TransceiverBase, DivergentTransceiver)
        returns (address)
    {
        return super._parityAddress(chainKey);
    }

    function predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        public
        view
        override(TransceiverBase, ZkSyncTransceiver)
        returns (address)
    {
        return super.predictCrossAccount(owner, salt, homeChainKey);
    }

    function _deployAccount(bytes32 salt) internal override(TransceiverBase, ZkSyncTransceiver) returns (address) {
        return super._deployAccount(salt);
    }
}

contract TronSym is TronTransceiver, SymHarness {
    function initialize(TransceiverConfig memory c, bytes32 hash) external initializer {
        __DivergentTransceiver_init(c, hash);
    }

    /// @dev The overrides below only name both bases, as Solidity requires where each supplies
    ///      an implementation; `super` resolves by linearization to the one that does the work.
    function _parityAddress(bytes32 chainKey)
        internal
        view
        override(TransceiverBase, DivergentTransceiver)
        returns (address)
    {
        return super._parityAddress(chainKey);
    }

    function predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        public
        view
        override(TransceiverBase, TronTransceiver)
        returns (address)
    {
        return super.predictCrossAccount(owner, salt, homeChainKey);
    }
}

/// @dev The zkSync and Tron transceivers. Forge runs Ethereum's EVM, so these pin that each
///      derives with its chain's formula, that the formula reaches the owner and the default
///      counterpart, and that account creation fails closed here rather than misdeploying.
contract DivergentTransceiverTest is Test {
    bytes32 constant HASH = keccak256("zksolc CrossProxy");
    bytes32 constant SALT = keccak256("account");
    bytes32 constant PROVIDER_SALT = keccak256("provider");
    address msig = address(0x5165);
    address alice = address(0xA11CE);

    function _config() internal returns (TransceiverConfig memory) {
        return TransceiverConfig({
            gateways: new address[](0),
            transmitterImplementation: address(new RecordingTransmitter()),
            receiverImplementation: address(new Rcv()),
            governorOwner: msig,
            governorSalt: bytes32(0),
            governorHome: Erc7930.encodeEvmChain(1),
            treasury: address(0x7EA5),
            chainRegistry: IChainRegistryRefs(address(0)),
            messageProvider: bytes32(0),
            minCounterpartProvenance: Provenance.Unresolved
        });
    }

    function _zk() internal returns (ZkSym t) {
        t = new ZkSym();
        t.initialize(_config(), HASH);
    }

    /* ================================= derivation ================================= */

    function testFuzz_zkSyncDerivesTheEraWay(address o, bytes32 salt, bytes32 home) public {
        ZkSym t = _zk();
        assertEq(
            t.predictCrossAccount(o, salt, home),
            AddressDerive.zksyncCreate2(address(t), t.accountSalt(o, salt, home), HASH, keccak256(""))
        );
    }

    function testFuzz_tronDerivesTheTronWay(address o, bytes32 salt, bytes32 home) public {
        TronSym t = new TronSym();
        t.initialize(_config(), HASH);
        assertEq(
            t.predictCrossAccount(o, salt, home),
            AddressDerive.tronCreate2(address(t), t.accountSalt(o, salt, home), HASH)
        );
    }

    /// @dev The owner is derived with this chain's formula, which is why the bytecode hash is
    ///      set before the base initializer runs.
    function test_theOwnerIsDerivedTheEraWay() public {
        ZkSym t = _zk();
        address viaEra = t.predictCrossAccount(msig, bytes32(0), ChainKey.forEvm(1));
        address viaEthereum = Create2.computeAddress(
            t.accountSalt(msig, bytes32(0), ChainKey.forEvm(1)), t.CROSS_PROXY_INIT_CODE_HASH(), address(t)
        );

        assertEq(t.owner(), viaEra);
        assertTrue(viaEra != viaEthereum, "not the address Ethereum's formula gives");
    }

    /// @dev These chains always report, whatever the caller passed.
    function test_itAlwaysDiverges() public {
        assertTrue(_zk().addressesDiverge());
    }

    function test_aZeroBytecodeHashIsRefused() public {
        ZkSym t = new ZkSym();
        TransceiverConfig memory c = _config();
        vm.expectRevert(DivergentAccounts.ZeroAccountBytecodeHash.selector);
        t.initialize(c, bytes32(0));
    }

    /// @dev On Forge's EVM the deployment lands at Ethereum's address and the guard refuses.
    function test_accountCreationFailsClosedOnAnEthereumEvm() public {
        ZkSym t = _zk();
        address predicted = t.predictCrossAccount(alice, SALT, t.localChainKey());

        vm.prank(alice);
        vm.expectPartialRevert(TransceiverBase.AccountAddressMismatch.selector);
        t.createTransmitter(SALT);
        assertEq(predicted.code.length, 0);
    }

    /* ============================ the default counterpart ========================== */

    /// @dev This transceiver is not at its provider's address on parity chains, so the
    ///      default counterpart there is the registry's prediction, and nothing until the
    ///      provider's deployment is recorded.
    /// @dev A transmitter homed on zkSync records this as its receiver on a parity chain: the
    ///      account's address there under Ethereum's formula, not its own Era address.
    function test_aZkSyncHomePredictsItsReceiversTheEthereumWay() public {
        ZkSym t = _zk();
        ChainRegistry registry = new ChainRegistry(address(this), unseeded());
        bytes32 provider = registry.addMessageProvider("test");
        bytes32 base = registry.addChainKey(Erc7930.encodeEvmChain(8453), Provenance.Derived);
        registry.setProviderDeployment(
            provider, PROVIDER_SALT, keccak256("transceiver"), t.CROSS_PROXY_INIT_CODE_HASH()
        );
        vm.prank(t.owner());
        t.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Attested);

        address there = registry.predictTransceiver(base, provider);
        address receiver = Create2.computeAddress(
            t.accountSalt(alice, SALT, t.localChainKey()), t.CROSS_PROXY_INIT_CODE_HASH(), there
        );

        assertEq(t.predictReceiver(base, alice, SALT), abi.encodePacked(receiver));
        assertTrue(receiver != t.predictCrossAccount(alice, SALT, t.localChainKey()), "not the Era address");
    }

    function test_theDefaultCounterpartIsTheProvidersParityAddress() public {
        ZkSym t = _zk();
        ChainRegistry registry = new ChainRegistry(address(this), unseeded());
        bytes32 provider = registry.addMessageProvider("test");
        bytes32 base = registry.addChainKey(Erc7930.encodeEvmChain(8453), Provenance.Derived);

        vm.prank(t.owner());
        t.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Attested);

        vm.expectRevert(ChainRegistry.NoProviderDeployment.selector);
        t.counterpartOn(base);

        registry.setProviderDeployment(
            provider, PROVIDER_SALT, keccak256("transceiver"), t.CROSS_PROXY_INIT_CODE_HASH()
        );
        address expected = registry.predictTransceiver(base, provider);
        assertEq(t.counterpartOn(base), abi.encodePacked(expected));
        assertTrue(expected != address(t), "not this contract's own address");
    }
}
