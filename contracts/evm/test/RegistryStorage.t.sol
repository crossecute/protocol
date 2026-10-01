// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice The registry is the one contract upgraded after deployment, so its fields live at
///         the ERC-7201 location its annotation names and nothing occupies slot 0 onward.
contract RegistryStorageTest is Test {
    function test_storageLivesAtTheErc7201Location() public {
        address owner = address(0x5165);
        ChainRegistry registry = ChainRegistry(
            address(new ERC1967Proxy(address(new ChainRegistry()), abi.encodeCall(ChainRegistry.initialize, (owner))))
        );
        vm.prank(owner);
        registry.addChainKey(Erc7930.encodeEvmChain(1));

        bytes32 location =
            keccak256(abi.encode(uint256(keccak256("crossecute.storage.ChainRegistry")) - 1)) & ~bytes32(uint256(0xff));
        // The first field is `chainKeys`, whose first word is the length of its values array.
        assertEq(uint256(vm.load(address(registry), location)), 1);
        for (uint256 i; i < 8; ++i) {
            assertEq(vm.load(address(registry), bytes32(i)), bytes32(0));
        }
    }
}
