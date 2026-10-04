// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {unseeded} from "test/RegistrySeed.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice The registry is fixed (D6, D12): no upgrade path, and a chain's grade and CREATE2
///         factory are write-once. Suspension is the per-chain cut-off instead of re-grading.
contract RegistryFixedTest is Test {
    ChainRegistry registry;
    address owner = address(0x71E1);
    bytes BASE = Erc7930.encodeEvmChain(8453);

    function setUp() public {
        registry = new ChainRegistry(owner, unseeded());
    }

    /// @dev Configured once, at construction, with nothing that could replace its code.
    function test_thereIsNoUpgradeOrInitializePath() public {
        (bool upgrade,) =
            address(registry).call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(1), ""));
        assertFalse(upgrade, "no upgradeToAndCall");
        (bool init,) = address(registry).call(abi.encodeWithSignature("initialize(address)", address(this)));
        assertFalse(init, "no initialize");
        assertEq(registry.owner(), owner);
    }

    /// @dev Whether a chain reports its receivers follows from its grade, so the grade is fixed
    ///      at registration: the same grade again is a no-op, another one is refused.
    function test_aGradeIsWriteOnce() public {
        vm.startPrank(owner);
        bytes32 key = registry.addChainKey(BASE, Provenance.Derived);
        assertEq(registry.addChainKey(BASE, Provenance.Derived), key, "the same grade again");

        vm.expectRevert(ChainRegistry.AlreadySet.selector);
        registry.addChainKey(BASE, Provenance.Attested);
        vm.stopPrank();

        assertEq(uint8(registry.provenanceFor(key)), uint8(Provenance.Derived));
        (bool regrade,) = address(registry).call(abi.encodeWithSignature("setProvenance(bytes32,uint8)", key, 1));
        assertFalse(regrade, "no setter on the ABI");
    }

    /// @dev Removal does not reopen it: a chain added back keeps the grade it was given.
    function test_aGradeSurvivesRemoval() public {
        vm.startPrank(owner);
        bytes32 key = registry.addChainKey(BASE, Provenance.Attested);
        registry.removeChainKey(key);

        vm.expectRevert(ChainRegistry.AlreadySet.selector);
        registry.addChainKey(BASE, Provenance.Derived);

        registry.addChainKey(BASE, Provenance.Attested);
        vm.stopPrank();
        assertTrue(registry.hasChainKey(key), "back in the directory, under its first grade");
    }

    /// @dev The factory moves every predicted transceiver on the chain.
    function test_theFactoryIsWriteOnce() public {
        vm.startPrank(owner);
        bytes32 key = registry.addChainKey(BASE, Provenance.Derived);
        registry.setCreate2Factory(key, address(0xFAC7));
        registry.setCreate2Factory(key, address(0xFAC7));

        vm.expectRevert(ChainRegistry.AlreadySet.selector);
        registry.setCreate2Factory(key, address(0xFAC8));
        vm.stopPrank();

        assertEq(registry.create2Factory(key), address(0xFAC7));
    }

    /// @dev Suspension only refuses, so it can be lifted; it is the owner's, as every change is.
    function test_suspensionIsTheOwnersAndCanBeLifted() public {
        vm.prank(owner);
        bytes32 key = registry.addChainKey(BASE, Provenance.Derived);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.setSuspended(key, true);

        vm.startPrank(owner);
        registry.setSuspended(key, true);
        assertTrue(registry.isSuspended(key));
        registry.setSuspended(key, false);
        vm.stopPrank();
        assertFalse(registry.isSuspended(key));
    }
}
