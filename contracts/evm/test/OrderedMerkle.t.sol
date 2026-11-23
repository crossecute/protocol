// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {OrderedMerkle} from "src/messaging/OrderedMerkle.sol";
import {MerkleBuilder} from "test/signed/SignedFixtures.sol";

/// @dev External wrappers so `vm.expectRevert` sees the library's reverts.
contract OrderedMerkleHarness {
    function root(bytes32[] memory leafHashes) external pure returns (bytes32) {
        return OrderedMerkle.root(leafHashes);
    }

    function proof(bytes32[] memory leafHashes, uint256 index) external pure returns (bytes32[] memory) {
        return OrderedMerkle.proof(leafHashes, index);
    }
}

/// @dev Checked against `MerkleBuilder`, the fixtures' independent builder of the guard's tree.
contract OrderedMerkleTest is Test {
    OrderedMerkleHarness h = new OrderedMerkleHarness();

    function _leaves(uint256 n) internal pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            leaves[i] = OrderedMerkle.leafHash(abi.encode(i));
        }
    }

    function test_theLeafHashIsTheDoubleHashOfTheFields() public pure {
        bytes memory fields = abi.encode(uint256(7), address(0xA));
        assertEq(OrderedMerkle.leafHash(fields), keccak256(abi.encode(keccak256(fields))));
    }

    function testFuzz_rootAndProofsMatchTheIndependentBuilder(uint8 count, uint8 pick) public pure {
        uint256 n = bound(count, 1, 40);
        bytes32[] memory leaves = _leaves(n);
        uint256 index = bound(pick, 0, n - 1);
        bytes32 r = OrderedMerkle.root(leaves);
        bytes32[] memory p = OrderedMerkle.proof(leaves, index);
        assertEq(r, MerkleBuilder.root(leaves));
        assertEq(p, MerkleBuilder.proof(leaves, index));
        assertTrue(MerkleProof.verify(p, r, leaves[index]));
    }

    function test_oneLeafIsItsOwnRootWithAnEmptyProof() public pure {
        bytes32[] memory leaves = _leaves(1);
        assertEq(OrderedMerkle.root(leaves), leaves[0]);
        assertEq(OrderedMerkle.proof(leaves, 0).length, 0);
    }

    /// @dev Both read the caller's array without writing it, so one list serves root and every proof.
    function test_theCallersLeavesAreLeftAsTheyWere() public pure {
        bytes32[] memory leaves = _leaves(5);
        bytes32[] memory before = _leaves(5);
        OrderedMerkle.root(leaves);
        OrderedMerkle.proof(leaves, 3);
        assertEq(leaves, before);
    }

    function test_noLeavesIsRefused() public {
        vm.expectRevert(OrderedMerkle.NoLeaves.selector);
        h.root(new bytes32[](0));
        vm.expectRevert(abi.encodeWithSelector(OrderedMerkle.IndexOutOfRange.selector, 0, 0));
        h.proof(new bytes32[](0), 0);
    }

    function test_anIndexPastTheLastLeafIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(OrderedMerkle.IndexOutOfRange.selector, 3, 3));
        h.proof(_leaves(3), 3);
    }
}
