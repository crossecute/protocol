// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {AuthoritySelection, AuthorityUpdate} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "@crossecute/safe-guard/authority/ISourceAuthorityGuard.sol";
import {Call} from "src/messaging/Call.sol";
import {AuthorityGraph, AuthorityNode} from "src/messaging/authority/AuthorityGraph.sol";
import {AuthorityMutations} from "src/messaging/authority/AuthorityMutations.sol";
import {ChildUpdate} from "src/messaging/authority/ChildUpdate.sol";
import {IReceiverAuthority} from "src/messaging/authority/IReceiverAuthority.sol";
import {ReceiverAuthority} from "src/messaging/authority/ReceiverAuthority.sol";
import {AuthorityUpdateEncoding} from "src/messaging/authority/AuthorityUpdateEncoding.sol";
import {SafeQuorum} from "src/messaging/signed/SafeQuorum.sol";
import {SafeOwner, SafeAuthorityRecord, OWNER_EOA} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {SafeTxEvidence} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {ReceiverAuthorityFixture, ReceiverAuthorityTestBase} from "./ReceiverAuthorityFixture.sol";

contract AuthorityEncodingFixture {
    function ownershipBatchData(address guard, address safe, AuthorityUpdate memory update, Call[] memory calls)
        external
        pure
        returns (bytes memory)
    {
        return AuthorityUpdateEncoding.ownershipBatchData(guard, safe, update, calls);
    }

    function decodeOwnershipBatch(address guard, address safe, bytes memory data)
        external
        pure
        returns (AuthorityUpdate memory, Call[] memory)
    {
        return AuthorityUpdateEncoding.decodeOwnershipBatch(guard, safe, data);
    }
}

/// @dev A root with one EOA owner and no descendants, seeded as a bootstrap would; graph-pass
///      cases are in AuthorityGraphPass.t.sol.
contract ReceiverAuthorityTemplateTest is ReceiverAuthorityTestBase {
    address internal constant SAFE = 0x21D9c001b9233ead0386c40BD1ACe1F3E6733E3D;
    bytes32 internal constant HEAD = keccak256("bootstrap head");
    uint256 internal constant ALICE_KEY = 1;
    uint256 internal constant BOB_KEY = 2;
    ReceiverAuthorityFixture internal receiver;
    AuthorityEncodingFixture internal encoding;

    function setUp() public {
        receiver = _seeded(CHAIN);
        encoding = new AuthorityEncodingFixture();
    }

    function _seeded(uint256 chain) internal returns (ReceiverAuthorityFixture target) {
        target = new ReceiverAuthorityFixture(chain, SAFE);
        target.seed(HEAD, _graph(vm.addr(ALICE_KEY)));
    }

    function _graph(address owner) internal pure returns (AuthorityGraph memory g) {
        SafeOwner[] memory owners = new SafeOwner[](1);
        owners[0] = SafeOwner(owner, OWNER_EOA);
        g.nodes = new AuthorityNode[](1);
        g.nodes[0] = AuthorityNode(SafeAuthorityRecord(SAFE, 1, owners), bytes32(0));
    }

    function _submit(ReceiverAuthorityFixture target, SafeTxEvidence memory e, address owner) internal {
        target.submitAuthority(e, _graph(owner), new ChildUpdate[](0));
    }

    /// @dev An ownership change swapping the single owner `from` for `to`.
    function _rotation(AuthorityUpdate memory u, address from, address to, uint256 key, uint256 nonce, uint256 chain)
        internal
        pure
        returns (SafeTxEvidence memory)
    {
        Call[] memory mutations = new Call[](1);
        mutations[0] = Call(SAFE, 0, abi.encodeWithSignature("swapOwner(address,address,address)", SENTINEL, from, to));
        return _sign(_ownershipTx(SAFE, u, mutations, nonce), SAFE, chain, key);
    }

    function _selection(AuthorityUpdate memory u, uint256 key, uint256 nonce)
        internal
        pure
        returns (SafeTxEvidence memory)
    {
        return _sign(_selectionTx(u, nonce), SAFE, CHAIN, key);
    }

    function _update(ReceiverAuthorityFixture target, uint256 chain, address nextOwner)
        internal
        view
        returns (AuthorityUpdate memory)
    {
        return
            AuthorityUpdate(target.selection().updateHead, AuthorityUpdateEncoding.graphHash(chain, _graph(nextOwner)));
    }

    function _hash(SafeTxEvidence memory e) internal pure returns (bytes32) {
        return _hash(e, SAFE);
    }

    function testLinkedHandoffsRejectSecondFirstWithoutStateChange() public {
        address alice = vm.addr(ALICE_KEY);
        address bob = vm.addr(BOB_KEY);
        AuthorityUpdate memory u1 = _update(receiver, CHAIN, bob);
        SafeTxEvidence memory e1 = _rotation(u1, alice, bob, ALICE_KEY, 10, CHAIN);
        AuthorityUpdate memory u2 = AuthorityUpdate(_hash(e1), AuthorityUpdateEncoding.graphHash(CHAIN, _graph(alice)));
        SafeTxEvidence memory e2 = _rotation(u2, bob, alice, BOB_KEY, 12, CHAIN);
        bytes32 initialHead = receiver.selection().updateHead;
        vm.expectRevert(ReceiverAuthority.PreviousUpdateMismatch.selector);
        _submit(receiver, e2, alice);
        assertEq(receiver.selection().updateHead, initialHead);
        _submit(receiver, e1, bob);
        _submit(receiver, e2, alice);
        assertEq(receiver.selection().authorityHash, u2.newAuthorityHash);
    }

    function _handoffs() internal view returns (bytes[] memory submissions, bytes32 lastHead) {
        address alice = vm.addr(ALICE_KEY);
        address bob = vm.addr(BOB_KEY);
        SafeTxEvidence memory first = _rotation(_update(receiver, CHAIN, bob), alice, bob, ALICE_KEY, 10, CHAIN);
        SafeTxEvidence memory second = _rotation(
            AuthorityUpdate(_hash(first), AuthorityUpdateEncoding.graphHash(CHAIN, _graph(alice))),
            bob,
            alice,
            BOB_KEY,
            12,
            CHAIN
        );
        submissions = new bytes[](2);
        submissions[0] = abi.encode(first, _graph(bob), new ChildUpdate[](0));
        submissions[1] = abi.encode(second, _graph(alice), new ChildUpdate[](0));
        lastHead = _hash(second);
    }

    function testBatchVerifiesEachSuccessorUnderItsPredecessorQuorum() public {
        (bytes[] memory submissions, bytes32 lastHead) = _handoffs();
        receiver.submitAuthorityBatch(submissions);
        assertEq(receiver.selection().updateHead, lastHead);
        assertEq(
            receiver.selection().authorityHash, AuthorityUpdateEncoding.graphHash(CHAIN, _graph(vm.addr(ALICE_KEY)))
        );
        vm.expectRevert(ReceiverAuthority.PreviousUpdateMismatch.selector);
        receiver.submitAuthorityBatch(submissions);
    }

    function testBatchFailureRollsBackTheHeadAndNewCacheEntries() public {
        (bytes[] memory submissions,) = _handoffs();
        bytes memory valid = submissions[1];
        (SafeTxEvidence memory evidence, AuthorityGraph memory graph, ChildUpdate[] memory children) =
            abi.decode(valid, (SafeTxEvidence, AuthorityGraph, ChildUpdate[]));
        evidence.signedSafeTx.signatures = hex"01";
        submissions[1] = abi.encode(evidence, graph, children);
        vm.expectRevert();
        receiver.submitAuthorityBatch(submissions);
        assertEq(receiver.selection().updateHead, HEAD);
        vm.expectRevert(ReceiverAuthority.GraphNotCached.selector);
        receiver.graph(AuthorityUpdateEncoding.graphHash(CHAIN, _graph(vm.addr(BOB_KEY))));
        submissions[1] = valid;
        receiver.submitAuthorityBatch(submissions);
    }

    function testBatchRejectsEmptyMalformedAndBusySubmissions() public {
        vm.expectRevert(IReceiverAuthority.EmptyAuthorityBatch.selector);
        receiver.submitAuthorityBatch(new bytes[](0));
        (bool success,) =
            address(receiver).call(abi.encodePacked(IReceiverAuthority.submitAuthorityBatch.selector, hex"01"));
        assertFalse(success);
        (bytes[] memory submissions,) = _handoffs();
        receiver.setBusy(true);
        vm.expectRevert("application context busy");
        receiver.submitAuthorityBatch(submissions);
        assertEq(receiver.selection().updateHead, HEAD);
    }

    function testEightyAggregateOwnersRemainValidWithinImmediateCaps() public {
        AuthorityGraph memory next;
        next.nodes = new AuthorityNode[](17);
        SafeOwner[] memory rootOwners = new SafeOwner[](16);
        Call[] memory mutations = new Call[](16);
        for (uint256 i; i < 16; ++i) {
            address child = address(uint160(0xB000 + i));
            rootOwners[i] = SafeOwner(child, 1);
            SafeOwner[] memory owners = new SafeOwner[](4);
            for (uint256 j; j < 4; ++j) {
                owners[j] = SafeOwner(vm.addr(1000 + 4 * i + j), OWNER_EOA);
            }
            next.nodes[i + 1] = AuthorityNode(SafeAuthorityRecord(child, 2, owners), bytes32(i + 1));
        }
        // The first swap installs the last child; later additions produce the graph's owner order.
        mutations[0] = Call(
            SAFE,
            0,
            abi.encodeWithSignature(
                "swapOwner(address,address,address)", SENTINEL, vm.addr(ALICE_KEY), address(uint160(0xB00F))
            )
        );
        for (uint256 i = 1; i < 16; ++i) {
            mutations[i] = Call(
                SAFE,
                0,
                abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", address(uint160(0xB00F - i)), 1)
            );
        }
        next.nodes[0] = AuthorityNode(SafeAuthorityRecord(SAFE, 1, rootOwners), bytes32(0));
        bytes32 hash = AuthorityUpdateEncoding.graphHash(CHAIN, next);
        SafeTxEvidence memory evidence =
            _sign(_ownershipTx(SAFE, AuthorityUpdate(HEAD, hash), mutations, 90), SAFE, CHAIN, ALICE_KEY);
        receiver.submitAuthority(evidence, next, new ChildUpdate[](0));
        assertEq(receiver.selection().authorityHash, hash);
        assertEq(receiver.graph(hash).nodes.length, 17);
    }

    function testHugeSignedNonceDoesNotBlockLinkedLowerNonce() public {
        address alice = vm.addr(ALICE_KEY);
        address bob = vm.addr(BOB_KEY);
        AuthorityUpdate memory u1 = _update(receiver, CHAIN, bob);
        _submit(receiver, _rotation(u1, alice, bob, ALICE_KEY, type(uint256).max, CHAIN), bob);
        AuthorityUpdate memory u2 = _update(receiver, CHAIN, alice);
        _submit(receiver, _rotation(u2, bob, alice, BOB_KEY, 11, CHAIN), alice);
        assertEq(receiver.selection().authorityHash, u2.newAuthorityHash);
    }

    function testSameSignedEvidenceReusableOnAnotherReceiver() public {
        ReceiverAuthorityFixture other = _seeded(CHAIN);
        AuthorityUpdate memory u = _update(receiver, CHAIN, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _rotation(u, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), ALICE_KEY, 20, CHAIN);
        _submit(receiver, e, vm.addr(BOB_KEY));
        _submit(other, e, vm.addr(BOB_KEY));
        assertEq(receiver.selection().updateHead, other.selection().updateHead);
    }

    function testReplayBlockedAfterOriginalGraphReturns() public {
        address alice = vm.addr(ALICE_KEY);
        address bob = vm.addr(BOB_KEY);
        SafeTxEvidence memory e1 = _rotation(_update(receiver, CHAIN, bob), alice, bob, ALICE_KEY, 10, CHAIN);
        _submit(receiver, e1, bob);
        _submit(receiver, _rotation(_update(receiver, CHAIN, alice), bob, alice, BOB_KEY, 12, CHAIN), alice);
        vm.expectRevert(ReceiverAuthority.PreviousUpdateMismatch.selector);
        _submit(receiver, e1, bob);
    }

    function testExactDuplicateOfHeadRejected() public {
        address bob = vm.addr(BOB_KEY);
        SafeTxEvidence memory e =
            _rotation(_update(receiver, CHAIN, bob), vm.addr(ALICE_KEY), bob, ALICE_KEY, 10, CHAIN);
        _submit(receiver, e, bob);
        AuthoritySelection memory accepted = receiver.selection();
        vm.expectRevert(ReceiverAuthority.PreviousUpdateMismatch.selector);
        _submit(receiver, e, bob);
        assertEq(receiver.selection().updateHead, accepted.updateHead);
    }

    function testCompetingSuccessorCannotOverwriteAcceptedBranch() public {
        AuthorityUpdate memory first = _update(receiver, CHAIN, vm.addr(BOB_KEY));
        AuthorityUpdate memory competing = _update(receiver, CHAIN, vm.addr(ALICE_KEY));
        _submit(
            receiver, _rotation(first, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), ALICE_KEY, 10, CHAIN), vm.addr(BOB_KEY)
        );
        vm.expectRevert(ReceiverAuthority.PreviousUpdateMismatch.selector);
        _submit(receiver, _selection(competing, ALICE_KEY, 100), vm.addr(ALICE_KEY));
    }

    function testNewOwnersCannotSelfInstall() public {
        AuthorityUpdate memory u = _update(receiver, CHAIN, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _rotation(u, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), BOB_KEY, 10, CHAIN);
        vm.expectRevert(abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, SAFE, vm.addr(BOB_KEY)));
        _submit(receiver, e, vm.addr(BOB_KEY));
    }

    function testAlteredReplacementGraphRejected() public {
        AuthorityUpdate memory u = _update(receiver, CHAIN, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _rotation(u, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), ALICE_KEY, 10, CHAIN);
        vm.expectRevert(ReceiverAuthority.ReplacementHashMismatch.selector);
        _submit(receiver, e, vm.addr(ALICE_KEY));
    }

    function testOwnershipChangeRootMustBeMutationResult() public {
        // Signs a graph naming carol while its swap installs bob.
        AuthorityUpdate memory u = _update(receiver, CHAIN, vm.addr(3));
        SafeTxEvidence memory e = _rotation(u, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), ALICE_KEY, 10, CHAIN);
        vm.expectRevert(AuthorityMutations.MutationResultMismatch.selector);
        _submit(receiver, e, vm.addr(3));
    }

    function testSelectionCannotChangeRootRecord() public {
        AuthorityUpdate memory u = _update(receiver, CHAIN, vm.addr(BOB_KEY));
        vm.expectRevert(ReceiverAuthority.RootRecordMismatch.selector);
        _submit(receiver, _selection(u, ALICE_KEY, 10), vm.addr(BOB_KEY));
    }

    function testWrongSourceChainCannotReuseSignature() public {
        ReceiverAuthorityFixture other = _seeded(10);
        // Chain 10's own predecessor and graph hash, signed under chain 1's Safe domain.
        AuthorityUpdate memory u = _update(other, 10, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _rotation(u, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), ALICE_KEY, 10, CHAIN);
        // The signature recovers some other address under chain 10's domain.
        vm.expectPartialRevert(SafeQuorum.NotAnOwner.selector);
        _submit(other, e, vm.addr(BOB_KEY));
    }

    function testBusyContextBlocksUpdate() public {
        AuthorityUpdate memory u = _update(receiver, CHAIN, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _rotation(u, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), ALICE_KEY, 10, CHAIN);
        receiver.setBusy(true);
        vm.expectRevert("application context busy");
        _submit(receiver, e, vm.addr(BOB_KEY));
    }

    function testRootMustBeFirstNodeAtPositionZero() public {
        AuthorityUpdate memory u = _update(receiver, CHAIN, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _rotation(u, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), ALICE_KEY, 10, CHAIN);
        AuthorityGraph memory g = _graph(vm.addr(BOB_KEY));
        g.nodes[0].record.safe = address(0xBBBB);
        vm.expectRevert(ReceiverAuthority.WrongRoot.selector);
        receiver.submitAuthority(e, g, new ChildUpdate[](0));
        g = _graph(vm.addr(BOB_KEY));
        g.nodes[0].position = bytes32(uint256(1));
        vm.expectRevert(ReceiverAuthority.RootPositionNotZero.selector);
        receiver.submitAuthority(e, g, new ChildUpdate[](0));
    }

    function testSeedSetsHeadAndGraph() public view {
        AuthoritySelection memory current = receiver.selection();
        assertEq(current.updateHead, HEAD);
        assertEq(current.authorityHash, AuthorityUpdateEncoding.graphHash(CHAIN, _graph(vm.addr(ALICE_KEY))));
    }

    function testSeedOnlyOnceAndChecksShape() public {
        vm.expectRevert(ReceiverAuthority.AlreadySeeded.selector);
        receiver.seed(HEAD, _graph(vm.addr(BOB_KEY)));
        ReceiverAuthorityFixture other = new ReceiverAuthorityFixture(CHAIN, SAFE);
        vm.expectRevert(ReceiverAuthority.ZeroCommitment.selector);
        other.seed(bytes32(0), _graph(vm.addr(ALICE_KEY)));
        AuthorityGraph memory g = _graph(vm.addr(ALICE_KEY));
        g.nodes[0].record.safe = address(0xBBBB);
        vm.expectRevert(ReceiverAuthority.WrongRoot.selector);
        other.seed(HEAD, g);
    }

    function testActivationIsNeverAccepted() public {
        SafeTx memory tx_;
        tx_.to = GUARD;
        tx_.data = abi.encodeWithSelector(
            ISourceAuthorityGuard.activate.selector, AuthorityUpdateEncoding.graphHash(CHAIN, _graph(vm.addr(BOB_KEY)))
        );
        vm.expectRevert(ReceiverAuthority.ActivationNotAccepted.selector);
        _submit(receiver, _sign(tx_, SAFE, CHAIN, ALICE_KEY), vm.addr(BOB_KEY));
    }

    function testUpdateBeforeSeedRejected() public {
        ReceiverAuthorityFixture other = new ReceiverAuthorityFixture(CHAIN, SAFE);
        AuthorityUpdate memory u =
            AuthorityUpdate(bytes32(0), AuthorityUpdateEncoding.graphHash(CHAIN, _graph(vm.addr(ALICE_KEY))));
        vm.expectRevert(ReceiverAuthority.UnseededAuthority.selector);
        _submit(other, _selection(u, ALICE_KEY, 0), vm.addr(ALICE_KEY));
    }

    function testGraphAndRecordsReadBack() public {
        address alice = vm.addr(ALICE_KEY);
        address bob = vm.addr(BOB_KEY);
        _submit(receiver, _rotation(_update(receiver, CHAIN, bob), alice, bob, ALICE_KEY, 10, CHAIN), bob);
        AuthorityGraph memory stored = receiver.graph(receiver.selection().authorityHash);
        assertEq(stored.nodes.length, 1);
        assertEq(stored.nodes[0].record.owners[0].owner, bob);
        bytes32 aliceRecord = AuthorityUpdateEncoding.recordHash(_graph(alice).nodes[0].record);
        assertEq(receiver.record(aliceRecord).owners[0].owner, alice);
        vm.expectRevert(ReceiverAuthority.GraphNotCached.selector);
        receiver.graph(bytes32(uint256(1)));
    }

    function testOwnershipBatchPacksGuardCallThenSelfCalls() public view {
        AuthorityUpdate memory u = AuthorityUpdate(bytes32(uint256(1)), bytes32(uint256(2)));
        Call[] memory calls = new Call[](2);
        calls[0] = Call(SAFE, 0, abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", address(0xB), 1));
        calls[1] = Call(SAFE, 0, abi.encodeWithSignature("changeThreshold(uint256)", 2));
        bytes memory registration = abi.encodeCall(ISourceAuthorityGuard.registerOwnershipChange, (u));
        bytes memory expected = abi.encodeWithSignature(
            "multiSend(bytes)",
            bytes.concat(
                abi.encodePacked(uint8(0), GUARD, uint256(0), registration.length, registration),
                abi.encodePacked(uint8(0), SAFE, uint256(0), calls[0].data.length, calls[0].data),
                abi.encodePacked(uint8(0), SAFE, uint256(0), calls[1].data.length, calls[1].data)
            )
        );
        bytes memory data = encoding.ownershipBatchData(GUARD, SAFE, u, calls);
        assertEq(data, expected);
        (AuthorityUpdate memory decoded, Call[] memory mutations) = encoding.decodeOwnershipBatch(GUARD, SAFE, data);
        assertEq(decoded.previousUpdateHash, u.previousUpdateHash);
        assertEq(decoded.newAuthorityHash, u.newAuthorityHash);
        assertEq(mutations.length, 2);
        assertEq(mutations[1].data, calls[1].data);
    }

    function testOwnershipBatchRejectsExternalTargetValueAndUnknownSelector() public {
        AuthorityUpdate memory u;
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(0xB), 0, abi.encodeWithSignature("changeThreshold(uint256)", 1));
        vm.expectRevert(abi.encodeWithSelector(AuthorityUpdateEncoding.InvalidMutation.selector, 0));
        encoding.ownershipBatchData(GUARD, SAFE, u, calls);
        calls[0].target = SAFE;
        calls[0].value = 1;
        vm.expectRevert(abi.encodeWithSelector(AuthorityUpdateEncoding.InvalidMutation.selector, 0));
        encoding.ownershipBatchData(GUARD, SAFE, u, calls);
        calls[0].value = 0;
        calls[0].data = abi.encodeWithSignature("setGuard(address)", address(0xB));
        vm.expectRevert(abi.encodeWithSelector(AuthorityUpdateEncoding.InvalidMutation.selector, 0));
        encoding.ownershipBatchData(GUARD, SAFE, u, calls);
    }

    function testOwnershipBatchDecodeRejectsOtherEncodings() public {
        AuthorityUpdate memory u;
        Call[] memory calls = new Call[](1);
        calls[0] = Call(SAFE, 0, abi.encodeWithSignature("changeThreshold(uint256)", 1));
        bytes memory data = encoding.ownershipBatchData(GUARD, SAFE, u, calls);
        // Another guard address.
        vm.expectRevert(AuthorityUpdateEncoding.InvalidOwnershipBatch.selector);
        encoding.decodeOwnershipBatch(address(0x9999), SAFE, data);
        // Trailing bytes after the multiSend argument.
        vm.expectRevert(AuthorityUpdateEncoding.InvalidOwnershipBatch.selector);
        encoding.decodeOwnershipBatch(GUARD, SAFE, bytes.concat(data, bytes1(0)));
        // The guard call alone, without a mutation.
        bytes memory registration = abi.encodeCall(ISourceAuthorityGuard.registerOwnershipChange, (u));
        bytes memory alone = abi.encodeWithSignature(
            "multiSend(bytes)", abi.encodePacked(uint8(0), GUARD, uint256(0), registration.length, registration)
        );
        vm.expectRevert(AuthorityUpdateEncoding.InvalidOwnershipBatch.selector);
        encoding.decodeOwnershipBatch(GUARD, SAFE, alone);
    }
}
