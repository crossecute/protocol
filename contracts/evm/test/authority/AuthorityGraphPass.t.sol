// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {AuthorityUpdate} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {Call} from "src/messaging/Call.sol";
import {AuthorityGraph, AuthorityNode} from "src/messaging/authority/AuthorityGraph.sol";
import {AuthorityMutations} from "src/messaging/authority/AuthorityMutations.sol";
import {ChildUpdate} from "src/messaging/authority/ChildUpdate.sol";
import {ReceiverAuthorityTemplate} from "src/messaging/authority/ReceiverAuthorityTemplate.sol";
import {AuthorityUpdateEncoding} from "src/messaging/authority/AuthorityUpdateEncoding.sol";
import {SafeAuthorityGraph} from "src/messaging/signed/SafeAuthorityGraph.sol";
import {SafeQuorum} from "src/messaging/signed/SafeQuorum.sol";
import {SafeSignaturesUtils} from "src/messaging/signed/SafeSignaturesUtils.sol";
import {OWNER_EOA, OWNER_SAFE, SafeAuthorityRecord, SafeOwner} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {NestedSafeApproval, SafeTxEvidence} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {SafeSigs, Sig} from "../signed/SignedFixtures.sol";
import {ReceiverAuthorityFixture, ReceiverAuthorityTestBase} from "./ReceiverAuthorityFixture.sol";

/// @dev Root A = {alice, B}, B = {bob, C}, C = {carol}, all threshold 1; D = {dave} is outside
///      A's graph until added. setUp seeds A's receiver with that graph, as its bootstrap would.
contract AuthorityGraphPassTest is ReceiverAuthorityTestBase {
    uint256 internal constant ALICE = 1;
    uint256 internal constant BOB = 2;
    uint256 internal constant CAROL = 3;
    uint256 internal constant DAVE = 4;
    uint256 internal constant ERIN = 5;

    ReceiverAuthorityFixture internal receiver;
    uint256 internal nonce;

    function setUp() public {
        receiver = new ReceiverAuthorityFixture(CHAIN, _a());
        receiver.seed(keccak256("A head"), _graphA0());
    }

    /* ================================ T23 / T25 ================================ */

    function test_movesChildForwardByOneUpdate() public {
        (SafeTxEvidence memory b1, AuthorityGraph memory g1) = _b1(BOB);
        _selectA(_graph(_rA0(), _node(_rB1(), _hash(b1, _b())), _node(_rC0(), _pC0())), _children(_childUpdate(b1, g1)));
        AuthorityGraph memory stored = receiver.graph(receiver.selection().authorityHash);
        assertEq(stored.nodes[1].record.owners[0].owner, vm.addr(ERIN));
        assertEq(stored.nodes[1].position, _hash(b1, _b()));
    }

    function test_movesChildForwardBySeveralUpdates() public {
        (SafeTxEvidence memory b1, AuthorityGraph memory g1) = _b1(BOB);
        (SafeTxEvidence memory b2, AuthorityGraph memory g2) = _b2(b1);
        _selectA(
            _graph(_rA0(), _node(g2.nodes[0].record, _hash(b2, _b())), _node(_rC0(), _pC0())),
            _children(_childUpdate(b1, g1), _childUpdate(b2, g2))
        );
        assertEq(receiver.graph(receiver.selection().authorityHash).nodes[1].position, _hash(b2, _b()));
    }

    function test_rejectsChildBehindOrOffItsStoredPosition() public {
        (SafeTxEvidence memory b1, AuthorityGraph memory g1) = _b1(BOB);
        (SafeTxEvidence memory b2, AuthorityGraph memory g2) = _b2(b1);
        _selectA(
            _graph(_rA0(), _node(g2.nodes[0].record, _hash(b2, _b())), _node(_rC0(), _pC0())),
            _children(_childUpdate(b1, g1), _childUpdate(b2, g2))
        );
        bytes32 head = receiver.selection().updateHead;
        AuthorityGraph memory behind = _graph(_rA0(), _node(_rB1(), _hash(b1, _b())), _node(_rC0(), _pC0()));

        _expectSelectA(
            behind,
            new ChildUpdate[](0),
            abi.encodeWithSelector(ReceiverAuthorityTemplate.UnprovenPosition.selector, _b())
        );
        _expectSelectA(
            behind,
            _children(_childUpdate(b1, g1)),
            abi.encodeWithSelector(ReceiverAuthorityTemplate.UnprovenPredecessor.selector, 0)
        );
        _expectSelectA(
            _graph(_rA0(), _node(_rB1(), bytes32(uint256(123))), _node(_rC0(), _pC0())),
            new ChildUpdate[](0),
            abi.encodeWithSelector(ReceiverAuthorityTemplate.UnprovenPosition.selector, _b())
        );
        assertEq(receiver.selection().updateHead, head, "no writes");
    }

    function test_rejectsChildRecordOtherThanItsMutations() public {
        (SafeTxEvidence memory b1, AuthorityGraph memory g1) = _b1(BOB);
        bytes32 head = receiver.selection().updateHead;
        // A names B's new position with B's old record.
        _expectSelectA(
            _graph(_rA0(), _node(_rB0(), _hash(b1, _b())), _node(_rC0(), _pC0())),
            _children(_childUpdate(b1, g1)),
            abi.encodeWithSelector(ReceiverAuthorityTemplate.DescendantRecordMismatch.selector, _b())
        );
        // B signs a graph whose record is not the result of its swap.
        AuthorityGraph memory wrong = _graph(_rec(_b(), _list(_eoa(DAVE), _sub(_c()))), _node(_rC0(), _pC0()));
        SafeTxEvidence memory bad =
            _change(_b(), _pB0(), wrong, _swap(_b(), SENTINEL, vm.addr(BOB), vm.addr(ERIN)), BOB);
        _expectSelectA(
            _graph(_rA0(), _node(wrong.nodes[0].record, _hash(bad, _b())), _node(_rC0(), _pC0())),
            _children(_childUpdate(bad, wrong)),
            abi.encodeWithSelector(AuthorityMutations.MutationResultMismatch.selector)
        );
        assertEq(receiver.selection().updateHead, head, "no writes");
    }

    function test_rejectsLinkReplayedAgainstReturnedRecord() public {
        (SafeTxEvidence memory b1, AuthorityGraph memory g1) = _b1(BOB);
        // B goes bob, erin, bob: its record returns but its position does not.
        AuthorityGraph memory g2 = _graph(_rB0(), _node(_rC0(), _pC0()));
        SafeTxEvidence memory b2 =
            _change(_b(), _hash(b1, _b()), g2, _swap(_b(), SENTINEL, vm.addr(ERIN), vm.addr(BOB)), ERIN);
        _selectA(
            _graph(_rA0(), _node(_rB0(), _hash(b2, _b())), _node(_rC0(), _pC0())),
            _children(_childUpdate(b1, g1), _childUpdate(b2, g2))
        );
        _expectSelectA(
            _graph(_rA0(), _node(_rB1(), _hash(b1, _b())), _node(_rC0(), _pC0())),
            _children(_childUpdate(b1, g1)),
            abi.encodeWithSelector(ReceiverAuthorityTemplate.UnprovenPredecessor.selector, 0)
        );
    }

    /* =================================== T29 =================================== */

    function test_childOwnReceiverOnAbandonedBranchIsNotRead() public {
        ReceiverAuthorityFixture bReceiver = new ReceiverAuthorityFixture(CHAIN, _b());
        bReceiver.seed(_pB0(), _graphB0());
        SafeTxEvidence memory abandoned = _select(_b(), _pB0(), _graphB0(), BOB);
        bReceiver.submitAuthority(abandoned, _graphB0(), new ChildUpdate[](0));

        (SafeTxEvidence memory b1, AuthorityGraph memory g1) = _b1(BOB);
        _selectA(_graph(_rA0(), _node(_rB1(), _hash(b1, _b())), _node(_rC0(), _pC0())), _children(_childUpdate(b1, g1)));
        assertEq(bReceiver.selection().updateHead, _hash(abandoned, _b()), "B's own receiver unchanged");
    }

    /* =================================== T30 =================================== */

    function test_addsSafeAsNamed() public {
        _addD(new ChildUpdate[](0), _pD0(), _rD0());
        assertEq(receiver.graph(receiver.selection().authorityHash).nodes[1].position, _pD0());
    }

    function test_reAddsRemovedSafeAtEarlierPosition() public {
        (, AuthorityGraph memory g1) = _d1();
        _addD(new ChildUpdate[](0), keccak256("D position 1"), g1.nodes[0].record);

        Call[] memory removal = new Call[](1);
        removal[0] = Call(_a(), 0, abi.encodeWithSelector(AuthorityUpdateEncoding.REMOVE_OWNER, SENTINEL, _d(), 1));
        bytes32 head = receiver.selection().updateHead;
        receiver.submitAuthority(_change(_a(), head, _graphA0(), removal, ALICE), _graphA0(), new ChildUpdate[](0));

        _addD(new ChildUpdate[](0), _pD0(), _rD0());
        assertEq(receiver.graph(receiver.selection().authorityHash).nodes[1].position, _pD0());
    }

    function test_rejectsAddedSafeAtZeroPositionOrWithInvalidRecord() public {
        bytes32 head = receiver.selection().updateHead;
        AuthorityGraph memory g = _graphWithD(bytes32(0), _rD0());
        _expectSubmitA(
            _change(_a(), head, g, _addOwner(_a(), _d()), ALICE),
            g,
            new ChildUpdate[](0),
            abi.encodeWithSelector(ReceiverAuthorityTemplate.UnprovenPosition.selector, _d())
        );
        SafeAuthorityRecord memory zero = _rD0();
        zero.threshold = 0;
        g = _graphWithD(_pD0(), zero);
        _expectSubmitA(
            _change(_a(), head, g, _addOwner(_a(), _d()), ALICE),
            g,
            new ChildUpdate[](0),
            abi.encodeWithSelector(SafeAuthorityGraph.InvalidThreshold.selector, _d(), 0, 1)
        );
    }

    /* =================================== T31 =================================== */

    function test_nestedVoterCountsUnderNamedPosition() public {
        // B's update is voted by C under the position B's graph names for C, which A stores.
        (SafeTxEvidence memory b1, AuthorityGraph memory g1) = _b1ByC(CAROL);
        _selectA(_graph(_rA0(), _node(_rB1(), _hash(b1, _b())), _node(_rC0(), _pC0())), _children(_childUpdate(b1, g1)));
    }

    function test_nestedVoterDoesNotCountUnderAnotherRecord() public {
        // dave never owns C at the position B's graph names.
        (SafeTxEvidence memory byDave, AuthorityGraph memory g1) = _b1ByC(DAVE);
        _expectSelectA(
            _graph(_rA0(), _node(_rB1(), _hash(byDave, _b())), _node(_rC0(), _pC0())),
            _children(_childUpdate(byDave, g1)),
            abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, _c(), vm.addr(DAVE))
        );
    }

    function test_nestedVoterBehindStoredPositionIsUnproven() public {
        _adoptC1();
        // C voted under a position behind the one A now stores, and no child update can prove a
        // position before the stored one.
        (SafeTxEvidence memory b1, AuthorityGraph memory g1) = _b1ByC(CAROL);
        _expectSelectA(
            _graph(_rA0(), _node(_rB1(), _hash(b1, _b())), _node(_rC1(), _pC1())),
            _children(_childUpdate(b1, g1)),
            abi.encodeWithSelector(ReceiverAuthorityTemplate.UnprovenVoter.selector, _c())
        );
    }

    function test_nestedVoterNeedsNamedRecord() public {
        // B's graph names C's stored position with C's later record.
        AuthorityGraph memory g1 = _graph(_rB1(), _node(_rC1(), _pC0()));
        AuthorityUpdate memory u = AuthorityUpdate(_pB0(), AuthorityUpdateEncoding.graphHash(CHAIN, g1));
        Call[] memory swap = _swap(_b(), SENTINEL, vm.addr(BOB), vm.addr(ERIN));
        SafeTxEvidence memory e = _signByChild(_ownershipTx(_b(), u, swap, 7), _b(), _c(), CAROL);
        _expectSelectA(
            _graph(_rA0(), _node(_rB1(), _hash(e, _b())), _node(_rC0(), _pC0())),
            _children(_childUpdate(e, g1)),
            abi.encodeWithSelector(ReceiverAuthorityTemplate.UnprovenVoter.selector, _c())
        );
    }

    function test_rejectsChildActivation() public {
        AuthorityGraph memory g = _graph(_rC1());
        SafeTxEvidence memory act = _sign(_activationTx(CHAIN, g), _c(), CHAIN, DAVE);
        _expectSelectA(
            _graph(_rA0(), _node(_rB0(), _pB0()), _node(_rC1(), _hash(act, _c()))),
            _children(_childUpdate(act, g)),
            abi.encodeWithSelector(ReceiverAuthorityTemplate.ActivationNotAccepted.selector)
        );
    }

    function test_removedSafeOwnerCannotVote() public {
        AuthorityGraph memory g1 = _graph(_rec(_b(), _list(_eoa(BOB))));
        Call[] memory removal = new Call[](1);
        removal[0] = Call(_b(), 0, abi.encodeWithSelector(AuthorityUpdateEncoding.REMOVE_OWNER, vm.addr(BOB), _c(), 1));
        AuthorityUpdate memory u = AuthorityUpdate(_pB0(), AuthorityUpdateEncoding.graphHash(CHAIN, g1));
        SafeTxEvidence memory byC = _signByChild(_ownershipTx(_b(), u, removal, ++nonce), _b(), _c(), CAROL);
        AuthorityGraph memory g = _graph(_rA0(), _node(g1.nodes[0].record, _hash(byC, _b())));
        _expectSelectA(
            g,
            _children(_childUpdate(byC, g1)),
            abi.encodeWithSelector(ReceiverAuthorityTemplate.UnprovenVoter.selector, _c())
        );

        SafeTxEvidence memory byBob = _sign(_ownershipTx(_b(), u, removal, nonce), _b(), CHAIN, BOB);
        g.nodes[1].position = _hash(byBob, _b());
        _selectA(g, _children(_childUpdate(byBob, g1)));
    }

    /* =================================== T24 =================================== */

    function test_adoptionCountsChildUnderItsNewPosition() public {
        (SafeTxEvidence memory b1, AuthorityGraph memory g1) = _b1(BOB);
        AuthorityGraph memory g = _graph(_rA0(), _node(_rB1(), _hash(b1, _b())), _node(_rC0(), _pC0()));
        SafeTx memory adoption = _selectATx(g);
        // bob left B in the update A adopts, so bob no longer signs for B.
        _expectSubmitA(
            _signByChild(adoption, _a(), _b(), BOB),
            g,
            _children(_childUpdate(b1, g1)),
            abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, _b(), vm.addr(BOB))
        );
        SafeTxEvidence memory byErin = _signByChild(adoption, _a(), _b(), ERIN);
        receiver.submitAuthority(byErin, g, _children(_childUpdate(b1, g1)));
        assertEq(receiver.selection().updateHead, _hash(byErin, _a()));
    }

    function test_keptPositionCountsChildUnderItsStoredRecord() public {
        SafeTx memory kept = _selectATx(_graphA0());
        _expectSubmitA(
            _signByChild(kept, _a(), _b(), ERIN),
            _graphA0(),
            new ChildUpdate[](0),
            abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, _b(), vm.addr(ERIN))
        );
        receiver.submitAuthority(_signByChild(kept, _a(), _b(), BOB), _graphA0(), new ChildUpdate[](0));
    }

    function test_newRootSafeOwnerCannotVoteItsInstallation() public {
        AuthorityGraph memory g = _graphWithD(_pD0(), _rD0());
        AuthorityUpdate memory u =
            AuthorityUpdate(receiver.selection().updateHead, AuthorityUpdateEncoding.graphHash(CHAIN, g));
        SafeTx memory install = _ownershipTx(_a(), u, _addOwner(_a(), _d()), ++nonce);
        // D is named by the new graph, but the root votes under its stored record.
        _expectSubmitA(
            _signByChild(install, _a(), _d(), DAVE),
            g,
            new ChildUpdate[](0),
            abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, _a(), _d())
        );
    }

    /* ================================ vote check ================================ */

    function test_eoaOwnerCannotVoteThroughContractSignature() public {
        SafeTx memory kept = _selectATx(_graphA0());
        Sig[] memory sigs = SafeSigs.one(_inline(vm.addr(ALICE), _txHash(kept), SafeSigs.one(SafeSigs.eoa(ALICE))));
        _expectSubmitA(
            _signed(kept, _a(), CHAIN, sigs),
            _graphA0(),
            new ChildUpdate[](0),
            abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, _a(), vm.addr(ALICE))
        );
    }

    function test_voterAtDepthTwoCountsUnderRootGraphPosition() public {
        _adoptC1();
        AuthorityGraph memory g = _graph(_rA0(), _node(_rB0(), _pB0()), _node(_rC1(), _pC1()));
        SafeTx memory kept = _selectATx(g);
        // A by B by C: C counts under the position A's graph names, where dave replaced carol.
        _expectSubmitA(
            _signed(kept, _a(), CHAIN, _byBByC(kept, CAROL)),
            g,
            new ChildUpdate[](0),
            abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, _c(), vm.addr(CAROL))
        );
        receiver.submitAuthority(_signed(kept, _a(), CHAIN, _byBByC(kept, DAVE)), g, new ChildUpdate[](0));
    }

    function test_emptyNestedSignatureNeedsOneSignedApproval() public {
        SafeTx memory kept = _selectATx(_graphA0());
        bytes32 digest = _txHash(kept);
        SafeTxEvidence memory e = _signed(kept, _a(), CHAIN, SafeSigs.one(SafeSigs.nested(_b(), "")));
        _expectSubmitA(
            e,
            _graphA0(),
            new ChildUpdate[](0),
            abi.encodeWithSelector(SafeQuorum.MissingNestedSafeApproval.selector, _b(), _nestedHash(digest, _b()))
        );
        NestedSafeApproval memory approval =
            SafeSigs.approval(_b(), digest, CHAIN, SafeSigs.one(SafeSigs.eoa(BOB)), address(0x5161));
        e.nestedApprovals = new NestedSafeApproval[](2);
        (e.nestedApprovals[0], e.nestedApprovals[1]) = (approval, approval);
        _expectSubmitA(
            e,
            _graphA0(),
            new ChildUpdate[](0),
            abi.encodeWithSelector(SafeQuorum.DuplicateNestedSafeApproval.selector, _b(), _nestedHash(digest, _b()))
        );
        e.nestedApprovals = new NestedSafeApproval[](1);
        e.nestedApprovals[0] = approval;
        receiver.submitAuthority(e, _graphA0(), new ChildUpdate[](0));
    }

    function test_thresholdCountsDistinctOwners() public {
        AuthorityGraph memory g =
            _graph(SafeAuthorityRecord(_a(), 2, _rA0().owners), _node(_rB0(), _pB0()), _node(_rC0(), _pC0()));
        Call[] memory raise = new Call[](1);
        raise[0] = Call(_a(), 0, abi.encodeWithSelector(AuthorityUpdateEncoding.CHANGE_THRESHOLD, 2));
        // The raise itself is voted under the stored threshold of one.
        bytes32 head = receiver.selection().updateHead;
        receiver.submitAuthority(_change(_a(), head, g, raise, ALICE), g, new ChildUpdate[](0));

        SafeTx memory kept = _selectATx(g);
        SafeTxEvidence memory byAlice = _sign(kept, _a(), CHAIN, ALICE);
        _expectSubmitA(
            byAlice,
            g,
            new ChildUpdate[](0),
            abi.encodeWithSelector(SafeSignaturesUtils.SignaturesTooShort.selector, _a())
        );
        SafeTxEvidence memory twice = _sign(kept, _a(), CHAIN, ALICE);
        twice.signedSafeTx.signatures = bytes.concat(byAlice.signedSafeTx.signatures, byAlice.signedSafeTx.signatures);
        _expectSubmitA(
            twice, g, new ChildUpdate[](0), abi.encodeWithSelector(SafeQuorum.SignersNotAscending.selector, _a())
        );
        Sig[] memory both =
            SafeSigs.two(SafeSigs.eoa(ALICE), _inline(_b(), _txHash(kept), SafeSigs.one(SafeSigs.eoa(BOB))));
        receiver.submitAuthority(_signed(kept, _a(), CHAIN, both), g, new ChildUpdate[](0));
    }

    /// @dev B's entry over A's `tx_`, carrying C's entry signed by C's owner `key`.
    function _byBByC(SafeTx memory tx_, uint256 key) internal pure returns (Sig[] memory) {
        bytes32 digest = _txHash(tx_);
        Sig memory byC = _inline(_c(), _nestedHash(digest, _b()), SafeSigs.one(SafeSigs.eoa(key)));
        return SafeSigs.one(_inline(_b(), digest, SafeSigs.one(byC)));
    }

    /// @dev A's selectAuthority of `g` after its stored head, unsigned.
    function _selectATx(AuthorityGraph memory g) internal returns (SafeTx memory) {
        AuthorityUpdate memory u =
            AuthorityUpdate(receiver.selection().updateHead, AuthorityUpdateEncoding.graphHash(CHAIN, g));
        return _selectionTx(u, ++nonce);
    }

    function _txHash(SafeTx memory tx_) internal pure returns (bytes32) {
        return SafeHashes.transactionHash(tx_, _a(), CHAIN);
    }

    function _expectSubmitA(
        SafeTxEvidence memory e,
        AuthorityGraph memory g,
        ChildUpdate[] memory children,
        bytes memory reason
    ) internal {
        vm.expectRevert(reason);
        receiver.submitAuthority(e, g, children);
    }

    /* ============================ strict child updates ========================== */

    function test_rejectsUnusedChildUpdate() public {
        (SafeTxEvidence memory b1, AuthorityGraph memory g1) = _b1(BOB);
        _expectSelectA(
            _graphA0(),
            _children(_childUpdate(b1, g1)),
            abi.encodeWithSelector(ReceiverAuthorityTemplate.UnusedChildUpdate.selector, 0)
        );
    }

    function test_rejectsRepeatedChildUpdate() public {
        (SafeTxEvidence memory b1, AuthorityGraph memory g1) = _b1(BOB);
        _expectSelectA(
            _graph(_rA0(), _node(_rB1(), _hash(b1, _b())), _node(_rC0(), _pC0())),
            _children(_childUpdate(b1, g1), _childUpdate(b1, g1)),
            abi.encodeWithSelector(ReceiverAuthorityTemplate.RepeatedChildUpdate.selector, 1)
        );
    }

    function test_rejectsChildRecordOrGraphNotSigned() public {
        (SafeTxEvidence memory b1, AuthorityGraph memory g1) = _b1(BOB);
        AuthorityGraph memory g = _graph(_rA0(), _node(_rB1(), _hash(b1, _b())), _node(_rC0(), _pC0()));

        ChildUpdate memory child = _childUpdate(b1, g1);
        child.newRecord = _rB0();
        _expectSelectA(
            g, _children(child), abi.encodeWithSelector(ReceiverAuthorityTemplate.ChildRecordMismatch.selector, 0)
        );
        // B signs a graph whose root record names another Safe.
        AuthorityGraph memory elsewhere = _graph(_rec(_c(), _rB1().owners), _node(_rC0(), _pC0()));
        SafeTxEvidence memory e =
            _change(_b(), _pB0(), elsewhere, _swap(_b(), SENTINEL, vm.addr(BOB), vm.addr(ERIN)), BOB);
        child = _childUpdate(e, elsewhere);
        child.sourceSafe = _b();
        g.nodes[1].position = _hash(e, _b());
        _expectSelectA(
            g, _children(child), abi.encodeWithSelector(ReceiverAuthorityTemplate.ChildRecordMismatch.selector, 0)
        );
        child = _childUpdate(b1, g1);
        child.newGraphEntries[1].position = bytes32(uint256(1));
        g.nodes[1].position = _hash(b1, _b());
        _expectSelectA(
            g, _children(child), abi.encodeWithSelector(ReceiverAuthorityTemplate.ChildGraphHashMismatch.selector, 0)
        );

        // An owner kind outside EOA and Safe, even when signed. A names B with a valid record so
        // its own canonical check passes.
        AuthorityGraph memory odd =
            _graph(_rec(_b(), _list(SafeOwner(vm.addr(ERIN), 2), _sub(_c()))), _node(_rC0(), _pC0()));
        e = _change(_b(), _pB0(), odd, _swap(_b(), SENTINEL, vm.addr(BOB), vm.addr(ERIN)), BOB);
        g.nodes[1].position = _hash(e, _b());
        _expectSelectA(
            g,
            _children(_childUpdate(e, odd)),
            abi.encodeWithSelector(ReceiverAuthorityTemplate.ChildRecordMismatch.selector, 0)
        );
    }

    function test_rejectsChildSelectionThatChangesRecord() public {
        AuthorityGraph memory g1 = _graph(_rB1(), _node(_rC0(), _pC0()));
        SafeTxEvidence memory e = _select(_b(), _pB0(), g1, BOB);
        _expectSelectA(
            _graph(_rA0(), _node(_rB1(), _hash(e, _b())), _node(_rC0(), _pC0())),
            _children(_childUpdate(e, g1)),
            abi.encodeWithSelector(ReceiverAuthorityTemplate.ChildRecordMismatch.selector, 0)
        );
    }

    /* ================================ structure ================================= */

    function test_rejectsNonCanonicalOrCyclicGraph() public {
        _expectSelectA(
            _graph(_rA0(), _node(_rC0(), _pC0()), _node(_rB0(), _pB0())),
            new ChildUpdate[](0),
            abi.encodeWithSelector(SafeAuthorityGraph.NonCanonicalAuthorityGraph.selector)
        );
        AuthorityGraph memory cyclic =
            _graph(_rA0(), _node(_rB0(), _pB0()), _node(_rec(_c(), _list(_eoa(CAROL), _sub(_a()))), _pC0()));
        _expectSelectA(
            cyclic, new ChildUpdate[](0), abi.encodeWithSelector(SafeAuthorityGraph.OwnerCycle.selector, _a())
        );
    }

    function test_rejectsMoreThanSixteenOwners() public {
        SafeOwner[] memory owners = new SafeOwner[](17);
        for (uint256 i; i < owners.length; ++i) {
            owners[i] = _eoa(100 + i);
        }
        _expectSelectA(
            _graph(_rec(_a(), owners)),
            new ChildUpdate[](0),
            abi.encodeWithSelector(ReceiverAuthorityTemplate.TooManyGraphOwners.selector, _a())
        );
    }

    /* ================================= scenario ================================= */

    function _a() internal pure returns (address) {
        return address(0xA0A0);
    }

    function _b() internal pure returns (address) {
        return address(0xB0B0);
    }

    function _c() internal pure returns (address) {
        return address(0xC0C0);
    }

    function _d() internal pure returns (address) {
        return address(0xD0D0);
    }

    function _rA0() internal pure returns (SafeAuthorityRecord memory) {
        return _rec(_a(), _list(_eoa(ALICE), _sub(_b())));
    }

    function _rB0() internal pure returns (SafeAuthorityRecord memory) {
        return _rec(_b(), _list(_eoa(BOB), _sub(_c())));
    }

    function _rB1() internal pure returns (SafeAuthorityRecord memory) {
        return _rec(_b(), _list(_eoa(ERIN), _sub(_c())));
    }

    function _rC0() internal pure returns (SafeAuthorityRecord memory) {
        return _rec(_c(), _list(_eoa(CAROL)));
    }

    function _rC1() internal pure returns (SafeAuthorityRecord memory) {
        return _rec(_c(), _list(_eoa(DAVE)));
    }

    function _rD0() internal pure returns (SafeAuthorityRecord memory) {
        return _rec(_d(), _list(_eoa(DAVE)));
    }

    function _graphA0() internal pure returns (AuthorityGraph memory) {
        return _graph(_rA0(), _node(_rB0(), _pB0()), _node(_rC0(), _pC0()));
    }

    function _graphB0() internal pure returns (AuthorityGraph memory) {
        return _graph(_rB0(), _node(_rC0(), _pC0()));
    }

    function _pB0() internal pure returns (bytes32) {
        return keccak256("B position 0");
    }

    function _pC0() internal pure returns (bytes32) {
        return keccak256("C position 0");
    }

    function _pC1() internal pure returns (bytes32) {
        return _hash(_c1().evidence, _c());
    }

    function _pD0() internal pure returns (bytes32) {
        return keccak256("D position 0");
    }

    /// @dev B swaps bob for erin, keeping C at its stored position.
    function _b1(uint256 key) internal returns (SafeTxEvidence memory e, AuthorityGraph memory g) {
        g = _graph(_rB1(), _node(_rC0(), _pC0()));
        e = _change(_b(), _pB0(), g, _swap(_b(), SENTINEL, vm.addr(BOB), vm.addr(ERIN)), key);
    }

    /// @dev _b1 voted by C alone, through C's owner `key`.
    function _b1ByC(uint256 key) internal pure returns (SafeTxEvidence memory e, AuthorityGraph memory g) {
        g = _graph(_rB1(), _node(_rC0(), _pC0()));
        AuthorityUpdate memory u = AuthorityUpdate(_pB0(), AuthorityUpdateEncoding.graphHash(CHAIN, g));
        Call[] memory swap = _swap(_b(), SENTINEL, vm.addr(BOB), vm.addr(ERIN));
        e = _signByChild(_ownershipTx(_b(), u, swap, 7), _b(), _c(), key);
    }

    /// @dev B swaps erin for dave after _b1.
    function _b2(SafeTxEvidence memory b1) internal returns (SafeTxEvidence memory e, AuthorityGraph memory g) {
        g = _graph(_rec(_b(), _list(_eoa(DAVE), _sub(_c()))), _node(_rC0(), _pC0()));
        e = _change(_b(), _hash(b1, _b()), g, _swap(_b(), SENTINEL, vm.addr(ERIN), vm.addr(DAVE)), ERIN);
    }

    /// @dev C swaps carol for dave.
    function _c1() internal pure returns (ChildUpdate memory) {
        AuthorityGraph memory g = _graph(_rC1());
        AuthorityUpdate memory u = AuthorityUpdate(_pC0(), AuthorityUpdateEncoding.graphHash(CHAIN, g));
        Call[] memory swap = _swap(_c(), SENTINEL, vm.addr(CAROL), vm.addr(DAVE));
        return _childUpdate(_sign(_ownershipTx(_c(), u, swap, 1), _c(), CHAIN, CAROL), g);
    }

    /// @dev D swaps dave for erin.
    function _d1() internal returns (SafeTxEvidence memory e, AuthorityGraph memory g) {
        g = _graph(_rec(_d(), _list(_eoa(ERIN))));
        e = _change(_d(), _pD0(), g, _swap(_d(), SENTINEL, vm.addr(DAVE), vm.addr(ERIN)), DAVE);
    }

    /// @dev A adopts C's first update, so A holds C past the position B's graph names.
    function _adoptC1() internal {
        _selectA(_graph(_rA0(), _node(_rB0(), _pB0()), _node(_rC1(), _pC1())), _children(_c1()));
    }

    /// @dev A = {D, alice, B}: D goes first, as Safe's addOwnerWithThreshold places it.
    function _graphWithD(bytes32 dPosition, SafeAuthorityRecord memory dRecord)
        internal
        pure
        returns (AuthorityGraph memory g)
    {
        SafeAuthorityRecord memory root = _rec(_a(), _list(_sub(_d()), _eoa(ALICE), _sub(_b())));
        g.nodes = new AuthorityNode[](4);
        g.nodes[0] = _node(root, bytes32(0));
        g.nodes[1] = _node(dRecord, dPosition);
        g.nodes[2] = _node(_rB0(), _pB0());
        g.nodes[3] = _node(_rC0(), _pC0());
    }

    function _addD(ChildUpdate[] memory children, bytes32 dPosition, SafeAuthorityRecord memory dRecord) internal {
        AuthorityGraph memory g = _graphWithD(dPosition, dRecord);
        bytes32 head = receiver.selection().updateHead;
        receiver.submitAuthority(_change(_a(), head, g, _addOwner(_a(), _d()), ALICE), g, children);
    }

    /* ================================== builders ================================ */

    function _selectA(AuthorityGraph memory g, ChildUpdate[] memory children) internal {
        receiver.submitAuthority(_select(_a(), receiver.selection().updateHead, g, ALICE), g, children);
    }

    function _expectSelectA(AuthorityGraph memory g, ChildUpdate[] memory children, bytes memory reason) internal {
        _expectSubmitA(_select(_a(), receiver.selection().updateHead, g, ALICE), g, children, reason);
    }

    function _select(address safe, bytes32 previous, AuthorityGraph memory g, uint256 key)
        internal
        returns (SafeTxEvidence memory)
    {
        AuthorityUpdate memory u = AuthorityUpdate(previous, AuthorityUpdateEncoding.graphHash(CHAIN, g));
        return _sign(_selectionTx(u, ++nonce), safe, CHAIN, key);
    }

    function _change(address safe, bytes32 previous, AuthorityGraph memory g, Call[] memory mutations, uint256 key)
        internal
        returns (SafeTxEvidence memory)
    {
        AuthorityUpdate memory u = AuthorityUpdate(previous, AuthorityUpdateEncoding.graphHash(CHAIN, g));
        return _sign(_ownershipTx(safe, u, mutations, ++nonce), safe, CHAIN, key);
    }

    function _swap(address safe, address prev, address oldOwner, address newOwner)
        internal
        pure
        returns (Call[] memory calls)
    {
        calls = new Call[](1);
        calls[0] = Call(safe, 0, abi.encodeWithSelector(AuthorityUpdateEncoding.SWAP_OWNER, prev, oldOwner, newOwner));
    }

    function _addOwner(address safe, address owner) internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(safe, 0, abi.encodeWithSelector(AuthorityUpdateEncoding.ADD_OWNER, owner, 1));
    }

    function _rec(address safe, SafeOwner[] memory owners) internal pure returns (SafeAuthorityRecord memory) {
        return SafeAuthorityRecord(safe, 1, owners);
    }

    function _eoa(uint256 key) internal pure returns (SafeOwner memory) {
        return SafeOwner(vm.addr(key), OWNER_EOA);
    }

    function _sub(address safe) internal pure returns (SafeOwner memory) {
        return SafeOwner(safe, OWNER_SAFE);
    }

    function _list(SafeOwner memory a) internal pure returns (SafeOwner[] memory owners) {
        owners = new SafeOwner[](1);
        owners[0] = a;
    }

    function _list(SafeOwner memory a, SafeOwner memory b) internal pure returns (SafeOwner[] memory owners) {
        owners = new SafeOwner[](2);
        (owners[0], owners[1]) = (a, b);
    }

    function _list(SafeOwner memory a, SafeOwner memory b, SafeOwner memory c)
        internal
        pure
        returns (SafeOwner[] memory owners)
    {
        owners = new SafeOwner[](3);
        (owners[0], owners[1], owners[2]) = (a, b, c);
    }

    function _node(SafeAuthorityRecord memory r, bytes32 position) internal pure returns (AuthorityNode memory) {
        return AuthorityNode(r, position);
    }

    function _graph(SafeAuthorityRecord memory root) internal pure returns (AuthorityGraph memory g) {
        g.nodes = new AuthorityNode[](1);
        g.nodes[0] = _node(root, bytes32(0));
    }

    function _graph(SafeAuthorityRecord memory root, AuthorityNode memory n1)
        internal
        pure
        returns (AuthorityGraph memory g)
    {
        g.nodes = new AuthorityNode[](2);
        (g.nodes[0], g.nodes[1]) = (_node(root, bytes32(0)), n1);
    }

    function _graph(SafeAuthorityRecord memory root, AuthorityNode memory n1, AuthorityNode memory n2)
        internal
        pure
        returns (AuthorityGraph memory g)
    {
        g.nodes = new AuthorityNode[](3);
        (g.nodes[0], g.nodes[1], g.nodes[2]) = (_node(root, bytes32(0)), n1, n2);
    }

    function _children(ChildUpdate memory a) internal pure returns (ChildUpdate[] memory children) {
        children = new ChildUpdate[](1);
        children[0] = a;
    }

    function _children(ChildUpdate memory a, ChildUpdate memory b)
        internal
        pure
        returns (ChildUpdate[] memory children)
    {
        children = new ChildUpdate[](2);
        (children[0], children[1]) = (a, b);
    }
}
