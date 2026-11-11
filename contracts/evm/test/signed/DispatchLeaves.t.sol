// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DispatchLeaves} from "src/messaging/signed/DispatchLeaves.sol";
import {ExecutionLeaf, BootstrapLeaf} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {Call} from "src/messaging/Call.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {MerkleBuilder} from "test/signed/SignedFixtures.sol";

contract LeafHarness {
    /// @notice Expose execution-leaf hashing through an external harness.
    /// @dev Tests can compare the internal library's result with an independently constructed
    ///      expected encoding.
    function hash(ExecutionLeaf memory leaf) external pure returns (bytes32) {
        return DispatchLeaves.hash(leaf);
    }

    /// @notice Expose execution-ID hashing through the harness.
    /// @dev Tests need to distinguish execution identity from the Merkle hash that also
    ///      includes delivery attributes.
    function executionId(ExecutionLeaf memory leaf) external pure returns (bytes32) {
        return DispatchLeaves.executionId(leaf);
    }

    /// @notice Expose bootstrap-leaf hashing through the harness.
    /// @dev A separate wrapper makes the bootstrap overload unambiguous in encoding tests.
    function hashBootstrap(BootstrapLeaf memory leaf) external pure returns (bytes32) {
        return DispatchLeaves.hash(leaf);
    }

    /// @notice Expose Merkle proof verification through an external call.
    /// @dev Foundry can then assert the exact revert when a proof does not authorize the leaf.
    function requireProof(bytes32[] memory proof, bytes32 root, bytes32 leafHash) external pure {
        DispatchLeaves.requireProof(proof, root, leafHash);
    }
}

/// @dev The leaf encoding and tree shape the guard's `publishLeaves` and the issue fix (#108).
contract DispatchLeavesTest is Test {
    LeafHarness h = new LeafHarness();

    /// @notice Build a fixed execution leaf with a selectable nonce.
    /// @dev Stable fields make it clear which single-field mutation changed a hash.
    function _leaf(uint256 nonce) internal pure returns (ExecutionLeaf memory leaf) {
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(0xCAFE), 1, hex"1234");
        leaf.destination = Erc7930.encodeEvm(8453, address(0xBEEF));
        leaf.nonce = nonce;
        leaf.validAfter = 10;
        leaf.deadline = 20;
        leaf.calls = abi.encode(calls);
        leaf.attributes = new bytes[](1);
        leaf.attributes[0] = hex"aabbccdd0102";
    }

    /// @notice Compare the leaf hash with an independent double hash of its ordered fields.
    /// @dev This pins the wire commitment so reordering or omitting a field cannot silently
    ///      change authorization.
    function test_theLeafHashIsTheDoubleHashOfTheFieldsInOrder() public view {
        ExecutionLeaf memory l = _leaf(3);
        bytes memory encoded = abi.encode(l.destination, l.nonce, l.validAfter, l.deadline, l.calls, l.attributes);
        assertEq(h.hash(l), keccak256(abi.encode(keccak256(encoded))));
    }

    /// @notice Compare the execution ID with a hash that excludes provider attributes.
    /// @dev Replay recognition must identify the batch rather than the delivery settings used
    ///      to transport it.
    function test_theExecutionIdOmitsTheAttributes() public view {
        ExecutionLeaf memory l = _leaf(3);
        bytes memory encoded = abi.encode(l.destination, l.nonce, l.validAfter, l.deadline, l.calls);
        assertEq(h.executionId(l), keccak256(abi.encode(keccak256(encoded))));
    }

    /// @notice Change delivery attributes and compare both hashes.
    /// @dev A proof must bind provider options while the receiver still recognizes an already
    ///      executed batch.
    function test_changingOnlyTheAttributesChangesTheHashAndKeepsTheId() public view {
        ExecutionLeaf memory a = _leaf(3);
        ExecutionLeaf memory b = _leaf(3);
        b.attributes[0] = hex"aabbccdd0103";
        assertTrue(h.hash(a) != h.hash(b));
        assertEq(h.executionId(a), h.executionId(b));
    }

    /// @notice Mutate each committed execution field and check that its leaf hash changes.
    /// @dev No destination, ordering, timing, call or provider option may escape Merkle
    ///      authorization.
    function test_everySignedFieldChangesTheHash() public view {
        bytes32 base = h.hash(_leaf(3));
        ExecutionLeaf memory l = _leaf(3);
        l.nonce = 4;
        assertTrue(h.hash(l) != base);
        l = _leaf(3);
        l.validAfter = 11;
        assertTrue(h.hash(l) != base);
        l = _leaf(3);
        l.deadline = 21;
        assertTrue(h.hash(l) != base);
        l = _leaf(3);
        l.destination = Erc7930.encodeEvm(8453, address(0xBEEE));
        assertTrue(h.hash(l) != base);
        l = _leaf(3);
        l.calls = abi.encode(new Call[](0));
        assertTrue(h.hash(l) != base);
    }

    /// @notice Compare a bootstrap hash with the independent four-field encoding.
    /// @dev Receiver setup needs its own pinned commitment distinct from execution leaves.
    function test_theBootstrapLeafHashIsTheDoubleHashOfItsFourFields() public view {
        BootstrapLeaf memory b = BootstrapLeaf(Erc7930.encodeEvm(8453, address(0xBEEF)), 1, 2, hex"00");
        bytes memory encoded = abi.encode(b.destination, b.validAfter, b.deadline, b.setupCalls);
        assertEq(h.hashBootstrap(b), keccak256(abi.encode(keccak256(encoded))));
    }

    /// @notice Verify a one-leaf tree using its leaf hash as root and no siblings.
    /// @dev Single-destination dispatches must not require an artificial Merkle level.
    function test_aSingleLeafIsItsOwnRootWithAnEmptyProof() public view {
        bytes32 leaf = h.hash(_leaf(0));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        assertEq(MerkleBuilder.root(leaves), leaf);
        h.requireProof(new bytes32[](0), leaf, leaf);
    }

    /// @notice Verify proofs for an odd-sized tree with its final hash carried upward.
    /// @dev The implementation must match the builder's unpaired-node rule rather than
    ///      inventing a sibling.
    function test_anOddLevelCarriesItsLastHashUpWithNoSibling() public view {
        bytes32[] memory leaves = new bytes32[](3);
        for (uint256 i; i < 3; ++i) {
            leaves[i] = h.hash(_leaf(i));
        }
        bytes32 root = MerkleBuilder.root(leaves);
        // The third leaf has no sibling on the first level, so its proof is one hash long.
        bytes32[] memory p = MerkleBuilder.proof(leaves, 2);
        assertEq(p.length, 1);
        bytes32 pair = leaves[0] < leaves[1]
            ? keccak256(abi.encode(leaves[0], leaves[1]))
            : keccak256(abi.encode(leaves[1], leaves[0]));
        assertEq(p[0], pair);
        for (uint256 i; i < 3; ++i) {
            h.requireProof(MerkleBuilder.proof(leaves, i), root, leaves[i]);
        }
    }

    /// @notice Generate tree sizes and leaf positions and verify the corresponding proof.
    /// @dev Varying both inputs catches tree-shape and index mistakes that fixed examples can
    ///      miss.
    function testFuzz_everyLeafProvesUnderTheRoot(uint8 count, uint8 pick) public view {
        uint256 n = bound(count, 1, 40);
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            leaves[i] = h.hash(_leaf(i));
        }
        uint256 index = bound(pick, 0, n - 1);
        h.requireProof(MerkleBuilder.proof(leaves, index), MerkleBuilder.root(leaves), leaves[index]);
    }

    /// @notice Attempt to verify a leaf under an unrelated root.
    /// @dev Possessing a valid proof for one authorization must not grant membership in
    ///      another.
    function test_aProofUnderAnotherRootIsRefused() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = h.hash(_leaf(0));
        leaves[1] = h.hash(_leaf(1));
        bytes32[] memory p = MerkleBuilder.proof(leaves, 0);
        vm.expectRevert(DispatchLeaves.InvalidProof.selector);
        h.requireProof(p, keccak256("other"), leaves[0]);
    }

    /// @notice Try to use an internal tree node as a leaf commitment.
    /// @dev Double hashing must prevent a tree node from being reinterpreted as authorized leaf
    ///      data.
    function test_anInternalNodeIsNotALeaf() public {
        bytes32[] memory leaves = new bytes32[](4);
        for (uint256 i; i < 4; ++i) {
            leaves[i] = h.hash(_leaf(i));
        }
        bytes32 root = MerkleBuilder.root(leaves);
        bytes32 node = leaves[0] < leaves[1]
            ? keccak256(abi.encode(leaves[0], leaves[1]))
            : keccak256(abi.encode(leaves[1], leaves[0]));
        // The node verifies as a node, but no leaf encoding double-hashes to it.
        bytes32[] memory upper = new bytes32[](1);
        upper[0] = MerkleBuilder.proof(leaves, 0)[1];
        h.requireProof(upper, root, node);
        assertTrue(keccak256(abi.encode(node)) != node);
    }
}
