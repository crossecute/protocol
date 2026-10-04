// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {TransceiverConfig} from "src/messaging/transceiver/SymmetricTransceiverBase.sol";
import {
    ZkSyncSymmetricTransceiver,
    TronSymmetricTransceiver
} from "src/messaging/transceiver/DivergentSymmetricTransceiver.sol";
import {DivergentAccounts} from "src/messaging/transceiver/DivergentAccounts.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {DivergentSymmetricTransceiver} from "src/messaging/transceiver/DivergentSymmetricTransceiver.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {SymHarness, Rcv, RecordingTransmitter} from "test/SymmetricTransceiver.t.sol";

contract ZkSym is ZkSyncSymmetricTransceiver, SymHarness {
    function initialize(TransceiverConfig memory c, bytes32 hash) external initializer {
        __DivergentSymmetric_init(c, hash);
    }

    /// @dev The overrides below only name both bases, as Solidity requires where each supplies
    ///      an implementation; `super` resolves by linearization to the one that does the work.
    function _parityAddress(bytes32 chainKey)
        internal
        view
        override(HubTransceiverBase, DivergentSymmetricTransceiver)
        returns (address)
    {
        return super._parityAddress(chainKey);
    }

    function predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        public
        view
        override(TransceiverBase, ZkSyncSymmetricTransceiver)
        returns (address)
    {
        return super.predictCrossAccount(owner, salt, homeChainKey);
    }

    function _deployAccount(bytes32 salt)
        internal
        override(TransceiverBase, ZkSyncSymmetricTransceiver)
        returns (address)
    {
        return super._deployAccount(salt);
    }
}

contract TronSym is TronSymmetricTransceiver, SymHarness {
    function initialize(TransceiverConfig memory c, bytes32 hash) external initializer {
        __DivergentSymmetric_init(c, hash);
    }

    /// @dev The overrides below only name both bases, as Solidity requires where each supplies
    ///      an implementation; `super` resolves by linearization to the one that does the work.
    function _parityAddress(bytes32 chainKey)
        internal
        view
        override(HubTransceiverBase, DivergentSymmetricTransceiver)
        returns (address)
    {
        return super._parityAddress(chainKey);
    }

    function predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        public
        view
        override(TransceiverBase, TronSymmetricTransceiver)
        returns (address)
    {
        return super.predictCrossAccount(owner, salt, homeChainKey);
    }
}

/// @dev The zkSync and Tron transceivers. Forge runs Ethereum's EVM, so these pin that each
///      derives with its chain's formula, that the formula reaches the owner and the default
///      counterpart, and that account creation fails closed here rather than misdeploying.
contract DivergentSymmetricTransceiverTest is Test {
    bytes32 constant HASH = keccak256("zksolc CrossProxy");
    bytes32 constant SALT = keccak256("account");
    bytes32 constant PROVIDER_SALT = keccak256("provider");
    address msig = address(0x5165);
    address alice = address(0xA11CE);

    function _config(bool diverges) internal returns (TransceiverConfig memory) {
        return TransceiverConfig({
            gateways: new address[](0),
            transmitterImplementation: address(new RecordingTransmitter()),
            receiverImplementation: address(new Rcv()),
            governorOwner: msig,
            governorSalt: bytes32(0),
            governorHome: ChainKey.forEvm(1),
            treasury: address(0x7EA5),
            addressesDiverge: diverges
        });
    }

    function _zk() internal returns (ZkSym t) {
        t = new ZkSym();
        t.initialize(_config(false), HASH);
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
        t.initialize(_config(false), HASH);
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
        TransceiverConfig memory c = _config(false);
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
    function test_theDefaultCounterpartIsTheProvidersParityAddress() public {
        ZkSym t = _zk();
        ChainRegistry registry = ChainRegistry(
            address(
                new ERC1967Proxy(
                    address(new ChainRegistry()), abi.encodeCall(ChainRegistry.initialize, (address(this)))
                )
            )
        );
        bytes32 provider = registry.addMessageProvider("test");
        bytes32 base = registry.addChainKey(Erc7930.encodeEvmChain(8453));

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
