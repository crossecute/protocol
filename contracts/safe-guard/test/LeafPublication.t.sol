// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Vm} from "forge-std/Vm.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {ICrossecuteGuard} from "../src/ICrossecuteGuard.sol";
import {GuardTestBase} from "./GuardTestBase.sol";
import {RootCollider, TestTransmitter} from "./TestTransmitter.sol";

/// @dev What an indexer does with a publication: rebuild the levels from the leaf hashes and
///      collect a leaf's proof. A proof skips each level where the leaf's hash moves up unpaired.
library MerkleReference {
    /// @dev Execution leaves in #108's encoding, 448 bytes each. Leaves 0 to 2 match
    ///      `test_publish_matchesOffchainVector`.
    function executionLeaves(uint256 count) internal pure returns (bytes[] memory leaves) {
        leaves = new bytes[](count);
        bytes[] memory attributes = new bytes[](1);
        attributes[0] = hex"aa";
        for (uint256 i = 0; i < count; ++i) {
            leaves[i] = abi.encode(hex"000100000114", i, 0, 1000, hex"c0de", attributes);
        }
    }

    function leafHash(bytes memory leaf) internal pure returns (bytes32) {
        return keccak256(abi.encode(keccak256(leaf)));
    }

    function proof(bytes[] memory leaves, uint256 index) internal pure returns (bytes32[] memory siblings) {
        bytes32[] memory level = new bytes32[](leaves.length);
        for (uint256 i = 0; i < leaves.length; ++i) {
            level[i] = leafHash(leaves[i]);
        }
        siblings = new bytes32[](256);
        uint256 depth = 0;
        while (level.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < level.length) siblings[depth++] = level[sibling];
            bytes32[] memory next = new bytes32[]((level.length + 1) / 2);
            for (uint256 i = 0; i < next.length; ++i) {
                next[i] = 2 * i + 1 < level.length ? _node(level[2 * i], level[2 * i + 1]) : level[2 * i];
            }
            level = next;
            index >>= 1;
        }
        assembly ("memory-safe") {
            mstore(siblings, depth)
        }
    }

    function _node(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}

/// @dev Permissionless leaf publication and the published-root check on owner-signed `registerRoot`.
contract LeafPublicationTest is GuardTestBase {
    address internal constant STRANGER = address(0x5778A9);

    /// @dev Leaf hashes and root computed with `cast` from the same encodings, outside Solidity.
    function test_publish_matchesOffchainVector() public {
        bytes[] memory leaves = MerkleReference.executionLeaves(3);
        bytes32[3] memory leafHashes = [
            bytes32(0xbb78bf94c5e1c6f91b744da93971ac6777fc646ca26ab0005ef1e624277d7070),
            0x19cc3775f22e8e5247aee60d5789fc9dc2011767e187f9c8872263cb6a7edca3,
            0xf0bba0d846d5b46c2343ec2bf330ed19c35e1c41a202ad1c991c01b7a2f840b9
        ];
        bytes32 root = 0xaa82123f67075907e439bf4fe2b85cf4d0ab12f4d94de47506e1f6f835034819;

        for (uint256 i = 0; i < 3; ++i) {
            vm.expectEmit(true, true, false, true, address(guard));
            emit ICrossecuteGuard.LeafPublished(root, leafHashes[i], i);
        }
        vm.prank(STRANGER);
        assertEq(guard.publishLeaves(leaves), root);
        assertTrue(guard.isPublished(root));
    }

    function test_publish_singleLeafIsItsOwnRoot() public {
        bytes[] memory leaves = MerkleReference.executionLeaves(1);
        bytes32 root = guard.publishLeaves(leaves);
        assertEq(root, MerkleReference.leafHash(leaves[0]));
        assertEq(MerkleReference.proof(leaves, 0).length, 0);
    }

    function test_publish_rejectsEmpty() public {
        vm.expectRevert(ICrossecuteGuard.NoLeaves.selector);
        guard.publishLeaves(new bytes[](0));
    }

    /// @dev Republishing is allowed and changes nothing but the events.
    function test_publish_repeatable() public {
        bytes32 root = guard.publishLeaves(MerkleReference.executionLeaves(2));
        vm.prank(STRANGER);
        assertEq(guard.publishLeaves(MerkleReference.executionLeaves(2)), root);
        assertTrue(guard.isPublished(root));
    }

    /// @dev An indexer reads the leaves from the publication calldata, matches each to its event
    ///      and builds a proof the OpenZeppelin verifier accepts for the root in the event.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_publish_indexerReconstructsProofs(uint8 count) public {
        bytes[] memory leaves = MerkleReference.executionLeaves(bound(count, 1, 33));
        bytes memory input = abi.encodeCall(ICrossecuteGuard.publishLeaves, (leaves));

        vm.recordLogs();
        vm.prank(STRANGER);
        (bool success,) = address(guard).call(input);
        assertTrue(success);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 eventRoot = logs[0].topics[1];
        assertTrue(guard.isPublished(eventRoot));
        bytes[] memory recovered = abi.decode(_slice(input, 4), (bytes[]));
        assertEq(logs.length, recovered.length);
        for (uint256 i = 0; i < recovered.length; ++i) {
            assertEq(logs[i].topics[0], ICrossecuteGuard.LeafPublished.selector);
            assertEq(logs[i].topics[1], eventRoot);
            assertEq(logs[i].topics[2], MerkleReference.leafHash(recovered[i]));
            assertEq(abi.decode(logs[i].data, (uint256)), i);
            assertTrue(MerkleProof.verify(MerkleReference.proof(recovered, i), eventRoot, logs[i].topics[2]));
        }
    }

    function test_registerRoot_unpublishedFailsBeforeStaging() public {
        bytes32 root = guard.publishLeaves(MerkleReference.executionLeaves(3));
        bytes32 other = keccak256("unpublished");
        uint256 nonce = safe.nonce();

        bytes memory data = abi.encodeCall(TestTransmitter.registerRoot, (other));
        bytes memory signatures = _signFor(safe, _signers(), address(transmitter), 0, data, Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.RootNotPublished.selector, other));
        _execWith(safe, address(transmitter), 0, data, Enum.Operation.Call, signatures);
        assertEq(safe.nonce(), nonce);

        _registerRoot(safe, transmitter, root);
        assertEq(transmitter.registrations(), 1);
        assertEq(transmitter.lastRoot(), root);
    }

    function test_registerRoot_rejectedBeforePublication() public {
        bytes[] memory leaves = MerkleReference.executionLeaves(3);
        bytes32 root = MerkleReference.leafHash(leaves[0]);
        bytes memory data = abi.encodeCall(TestTransmitter.registerRoot, (root));
        bytes memory signatures = _signFor(safe, _signers(), address(transmitter), 0, data, Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.RootNotPublished.selector, root));
        _execWith(safe, address(transmitter), 0, data, Enum.Operation.Call, signatures);

        // The same signatures stay valid: the nonce did not advance.
        guard.publishLeaves(MerkleReference.executionLeaves(1));
        assertTrue(_execWith(safe, address(transmitter), 0, data, Enum.Operation.Call, signatures));
        assertEq(transmitter.lastRoot(), root);
    }

    /// @dev The transmitter receives the Safe's signed authorization, and the record is cleared in
    ///      the same transaction.
    function test_registerRoot_consumedAndCleared() public {
        bytes32 root = guard.publishLeaves(MerkleReference.executionLeaves(5));
        bytes memory data = abi.encodeCall(TestTransmitter.registerRoot, (root));
        bytes32 txHash = _txHash(safe, address(transmitter), 0, data, Enum.Operation.Call);
        bytes memory signatures = _sign(_signers(), txHash);

        _run(
            _execCallWith(safe, address(transmitter), 0, data, Enum.Operation.Call, signatures),
            _cleared(safe, _words(signatures))
        );
        assertEq(transmitter.lastSafeTxHash(), txHash);
        assertEq(transmitter.lastSignatures(), signatures);
    }

    /// @dev One publication serves every Safe on the guard. Each Safe's transmitter consumes that
    ///      Safe's own signatures.
    function test_registerRoot_publicationSharedAcrossSafes() public {
        Safe second = _newEoaSafe();
        TestTransmitter secondTransmitter = new TestTransmitter(address(second), sink);
        _install(second, _signers(), guard, _defaultConfig(), false);

        vm.prank(STRANGER);
        bytes32 root = guard.publishLeaves(MerkleReference.executionLeaves(3));

        bytes memory firstSignatures = _registerRoot(safe, transmitter, root);
        bytes memory secondSignatures = _registerRoot(second, secondTransmitter, root);
        assertEq(transmitter.lastSignatures(), firstSignatures);
        assertEq(secondTransmitter.lastSignatures(), secondSignatures);
        assertNotEq(keccak256(firstSignatures), keccak256(secondSignatures));
        assertEq(secondTransmitter.lastRoot(), root);
    }

    /// @dev Publication is the only gate on a matching selector. An unrelated target with a published
    ///      root leaves its record unconsumed, and the post-hook clears it.
    function test_registerRoot_unrelatedTargetCleared() public {
        RootCollider collider = new RootCollider();
        bytes32 root = guard.publishLeaves(MerkleReference.executionLeaves(2));
        bytes memory data = abi.encodeCall(RootCollider.registerRoot, (root));
        bytes memory signatures = _signFor(safe, _signers(), address(collider), 0, data, Enum.Operation.Call);

        _run(
            _execCallWith(safe, address(collider), 0, data, Enum.Operation.Call, signatures),
            _cleared(safe, _words(signatures))
        );
        assertEq(collider.calls(), 1);

        bytes memory unpublished = abi.encodeCall(RootCollider.registerRoot, (bytes32(0)));
        signatures = _signFor(safe, _signers(), address(collider), 0, unpublished, Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.RootNotPublished.selector, bytes32(0)));
        _execWith(safe, address(collider), 0, unpublished, Enum.Operation.Call, signatures);
    }

    function test_registerRoot_rejectsShortCalldata() public {
        bytes memory data = abi.encodePacked(TestTransmitter.registerRoot.selector, bytes31(0));
        bytes memory signatures = _signFor(safe, _signers(), address(transmitter), 0, data, Enum.Operation.Call);
        vm.expectRevert(bytes(""));
        _execWith(safe, address(transmitter), 0, data, Enum.Operation.Call, signatures);
    }

    function _registerRoot(Safe safe_, TestTransmitter transmitter_, bytes32 root)
        internal
        returns (bytes memory signatures)
    {
        bytes memory data = abi.encodeCall(TestTransmitter.registerRoot, (root));
        signatures = _signFor(safe_, _signers(), address(transmitter_), 0, data, Enum.Operation.Call);
        assertTrue(_execWith(safe_, address(transmitter_), 0, data, Enum.Operation.Call, signatures));
    }

    function _slice(bytes memory data, uint256 start) internal pure returns (bytes memory out) {
        out = new bytes(data.length - start);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = data[start + i];
        }
    }
}
