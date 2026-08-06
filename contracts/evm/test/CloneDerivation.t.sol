// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {VmDeriver} from "src/derivation/VmDeriver.sol";
import {ChainType} from "src/addressing/ChainType.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @dev Something with code, to clone.
contract Impl {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Predicting a RECEIVER address on a destination chain. Receivers are EIP-1167
///         clones, so this is what closes the gap between "we know where the transceiver
///         is" and "we know where the receiver will be".
contract CloneDerivationTest is Test {
    VmDeriver deriver;
    Impl impl;

    function setUp() public {
        deriver = new VmDeriver();
        impl = new Impl();
    }

    /// @dev THE LOAD-BEARING CHECK. The 55-byte EIP-1167 layout is hardcoded in
    ///      `AddressDerive.cloneInitCodeHash`. If OpenZeppelin's proxy bytecode ever differs
    ///      from it — including a future optimized variant — every predicted receiver
    ///      address is silently wrong. So it is checked against OZ, not against itself.
    function test_cloneInitCodeHashMatchesOpenZeppelin() public {
        bytes32 salt = keccak256("transmitter-x");
        address ozPredicted =
            Clones.predictDeterministicAddress(address(impl), salt, address(this));
        address ours = AddressDerive.clone2(address(this), address(impl), salt);
        assertEq(ours, ozPredicted, "clone initcode layout must match OZ");
    }

    /// @dev And against a clone that actually exists, not just against OZ's own math.
    function test_matchesAnActuallyDeployedClone() public {
        bytes32 salt = keccak256("transmitter-y");
        address deployed = Clones.cloneDeterministic(address(impl), salt);
        assertEq(AddressDerive.clone2(address(this), address(impl), salt), deployed);
        assertEq(Impl(deployed).ping(), 1, "the clone is live");
    }

    /// @dev Ethereum predicting a receiver on Base, with no message and no bridge trust.
    function test_evmCloneThroughDeriver() public view {
        address destTransceiver = address(0x7BAD);
        address destReceiverImpl = address(0xBEEF);
        bytes32 salt = keccak256(abi.encode(address(0x7A11))); // receiverSalt(transmitter)

        bytes memory params = abi.encode(
            VmDeriver.Scheme.EvmClone,
            abi.encode(destTransceiver, destReceiverImpl, salt)
        );
        bytes memory interop =
            deriver.deriveAddress(Erc7930.encodeEvmChain(8453), params);

        assertEq(
            Erc7930.toAddress(Erc7930.parseStrict(interop)),
            AddressDerive.clone2(destTransceiver, destReceiverImpl, salt)
        );
    }

    /// @dev Same inputs, different domain byte — Tron must not collide with Ethereum.
    function test_tronCloneDiffersFromEvmClone() public view {
        address destTransceiver = address(0x7BAD);
        address destReceiverImpl = address(0xBEEF);
        bytes32 salt = keccak256("s");

        bytes memory inner = abi.encode(destTransceiver, destReceiverImpl, salt);
        bytes memory tronChain = Erc7930.encodeEvmChain(728126428);

        bytes memory evmOut = deriver.deriveAddress(
            Erc7930.encodeEvmChain(1), abi.encode(VmDeriver.Scheme.EvmClone, inner)
        );
        bytes memory tronOut = deriver.deriveAddress(
            tronChain, abi.encode(VmDeriver.Scheme.TronClone, inner)
        );

        assertTrue(
            Erc7930.toAddress(Erc7930.parseStrict(evmOut))
                != Erc7930.toAddress(Erc7930.parseStrict(tronOut)),
            "0x41 vs 0xff must produce different addresses"
        );
        assertEq(
            Erc7930.toAddress(Erc7930.parseStrict(tronOut)),
            AddressDerive.tronCreate2(
                destTransceiver, salt, AddressDerive.cloneInitCodeHash(destReceiverImpl)
            )
        );
    }

    /// @dev Clones are an EVM construct. EraVM only deploys bytecode whose hash has been
    ///      published, and a 55-byte EVM proxy is not valid EraVM bytecode — a zkSync
    ///      "clone" is a real zksolc proxy, derived with `ZkSyncCreate2` instead.
    function test_cloneSchemesAreEvmOnly() public view {
        assertTrue(deriver.supportsScheme(ChainType.EIP155, uint8(VmDeriver.Scheme.EvmClone)));
        assertTrue(deriver.supportsScheme(ChainType.EIP155, uint8(VmDeriver.Scheme.TronClone)));
        assertFalse(deriver.supportsScheme(ChainType.SOLANA, uint8(VmDeriver.Scheme.EvmClone)));
        assertFalse(deriver.supportsScheme(ChainType.SUI, uint8(VmDeriver.Scheme.EvmClone)));
        assertFalse(
            deriver.supportsScheme(ChainType.STARKNET, uint8(VmDeriver.Scheme.EvmClone))
        );
    }

    function test_cloneInitCodeHashIsExposed() public view {
        assertEq(
            deriver.cloneInitCodeHash(address(impl)),
            AddressDerive.cloneInitCodeHash(address(impl))
        );
    }
}
