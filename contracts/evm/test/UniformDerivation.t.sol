// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IVmDeriver, VmDeriver} from "src/derivation/VmDeriver.sol";
import {ChainType} from "src/addressing/ChainType.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {Provenance} from "src/registry/ForeignRef.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice Covers the claim that resolution is uniform: the same three calls configure
///         any destination, and the same read returns its transceiver, regardless of VM.
contract UniformDerivationTest is Test {
    ChainRegistry registry;
    VmDeriver deriver;

    address owner = address(0xA11CE);
    bytes32 constant PROVIDER = keccak256("layerzero");

    function setUp() public {
        deriver = new VmDeriver();
        // Behind a proxy: the implementation disables initializers in its constructor,
        // matching the spec's assumption that every contract is an upgradeable proxy.
        ChainRegistry impl = new ChainRegistry();
        registry = ChainRegistry(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(ChainRegistry.initialize, (owner))
                )
            )
        );
        vm.startPrank(owner);
        registry.addMessageProvider("layerzero");
        vm.stopPrank();
    }

    /// @dev Wire one destination end to end and return its chainKey.
    function _wire(bytes memory chainIdentifier, bytes memory params, bytes32 transceiverId)
        internal
        returns (bytes32 chainKey)
    {
        vm.startPrank(owner);
        chainKey = registry.addChainKey(chainIdentifier);
        registry.setDeriver(chainKey, IVmDeriver(address(deriver)));
        registry.setDeriveParams(chainKey, params);
        registry.setTransceiverId(chainKey, PROVIDER, transceiverId);
        vm.stopPrank();
    }

    function test_evmCreate2_derivesAndStoresAsDerived() public {
        address factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        bytes32 salt = keccak256("crossecute.transceiver.v1");
        bytes32 initCodeHash = keccak256("initcode");

        bytes memory params = abi.encode(
            VmDeriver.Scheme.EvmCreate2, abi.encode(factory, salt, initCodeHash)
        );
        bytes32 chainKey =
            _wire(Erc7930.encodeEvmChain(8453), params, keccak256("base.transceiver"));

        // The uniform read agrees with the raw library derivation.
        address want = AddressDerive.create2(factory, salt, initCodeHash);
        bytes memory interop = registry.expectedTransceiver(chainKey);
        assertEq(Erc7930.toAddress(Erc7930.parseStrict(interop)), want);

        vm.prank(owner);
        (bytes32 id,) =
            registry.resolveTransceiver(chainKey, PROVIDER, keccak256(params));
        assertEq(id, keccak256("base.transceiver"));

        assertEq(registry.evmAddress(id), want);
        assertEq(
            uint8(registry.requireRef(id, Provenance.Derived).provenance),
            uint8(Provenance.Derived)
        );
    }

    /// @dev The point of normalizing: Solana configures through the same three calls and
    ///      reads back through the same function as an EVM chain.
    function test_solanaPda_usesIdenticalCallShape() public {
        bytes[] memory seeds = new bytes[](1);
        seeds[0] = bytes("crossecute");
        bytes32 programId = keccak256("program");

        bytes memory params =
            abi.encode(VmDeriver.Scheme.SolanaPda, abi.encode(seeds, uint8(255), programId));
        bytes memory solChain =
            Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");
        bytes32 chainKey = _wire(solChain, params, keccak256("solana.transceiver"));

        bytes memory interop = registry.expectedTransceiver(chainKey);
        Erc7930.Interop memory io = Erc7930.parseStrict(interop);
        assertEq(io.addr.length, 32, "solana address is 32 bytes");
        assertEq(
            bytes32(io.addr),
            AddressDerive.solanaCreateProgramAddress(seeds, 255, programId)
        );

        vm.prank(owner);
        registry.resolveTransceiver(chainKey, PROVIDER, keccak256(params));
        assertEq(registry.get(keccak256("solana.transceiver")).chainKey, chainKey);
    }

    function test_resolveTransceiver_revertsOnStaleParamsCommitment() public {
        bytes memory params = abi.encode(
            VmDeriver.Scheme.EvmCreate3, abi.encode(address(0xBEEF), bytes32(uint256(1)))
        );
        bytes32 chainKey = _wire(Erc7930.encodeEvmChain(1), params, keccak256("eth.tx"));

        vm.prank(owner);
        vm.expectRevert(ChainRegistry.ParamsCommitmentMismatch.selector);
        registry.resolveTransceiver(chainKey, PROVIDER, keccak256("something else"));
    }

    /// @dev Ethereum, zkSync, and Tron are all eip155 with different CREATE2 formulas,
    ///      so the scheme must be pinned per chain rather than inferred from chain type.
    function test_schemeIsCheckedAgainstChainType() public {
        vm.startPrank(owner);
        bytes32 chainKey = registry.addChainKey(Erc7930.encodeEvmChain(1));
        registry.setDeriver(chainKey, IVmDeriver(address(deriver)));

        // A Solana PDA is not a legal scheme on an eip155 chain.
        bytes memory bad =
            abi.encode(VmDeriver.Scheme.SolanaPda, abi.encode(new bytes[](0), uint8(0), bytes32(0)));
        vm.expectRevert(ChainRegistry.SchemeNotSupported.selector);
        registry.setDeriveParams(chainKey, bad);
        vm.stopPrank();

        assertTrue(deriver.supportsScheme(ChainType.EIP155, uint8(VmDeriver.Scheme.TronCreate2)));
        assertFalse(deriver.supportsScheme(ChainType.EIP155, uint8(VmDeriver.Scheme.SolanaPda)));
        // Aptos and Starknet are deliberately underivable.
        assertFalse(deriver.supportsScheme(ChainType.APTOS, uint8(VmDeriver.Scheme.EvmCreate2)));
        assertFalse(deriver.supportsScheme(ChainType.STARKNET, uint8(VmDeriver.Scheme.EvmCreate2)));
    }

    /// @dev One unconfigured chain must not blind the view of every other destination.
    function test_expectedTransceivers_skipsUnconfiguredChains() public {
        bytes memory params = abi.encode(
            VmDeriver.Scheme.EvmCreate3, abi.encode(address(0xF00D), bytes32(uint256(7)))
        );
        _wire(Erc7930.encodeEvmChain(10), params, keccak256("op.tx"));

        // A second chain with no deriver and no route at all.
        vm.prank(owner);
        registry.addChainKey(Erc7930.encodeEvmChain(42161));

        (bytes32[] memory keys,, bytes[] memory interops) =
            registry.expectedTransceivers(PROVIDER);
        assertEq(keys.length, 2);

        uint256 populated;
        for (uint256 i; i < interops.length; ++i) {
            if (interops[i].length != 0) ++populated;
        }
        assertEq(populated, 1, "only the configured chain resolves");
    }
}
