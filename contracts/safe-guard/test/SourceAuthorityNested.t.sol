// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {AuthorityGraph} from "crossecute/messaging/authority/AuthorityGraph.sol";
import {AuthorityUpdateEncoding} from "crossecute/messaging/authority/AuthorityUpdateEncoding.sol";
import {ChildUpdate} from "crossecute/messaging/authority/ChildUpdate.sol";
import {SafeQuorum} from "crossecute/messaging/signed/SafeQuorum.sol";
import {Call} from "crossecute/messaging/Call.sol";
import {
    OWNER_EOA,
    OWNER_SAFE,
    SafeAuthorityRecord,
    SafeOwner
} from "crossecute/messaging/signed/types/SafeAuthorityTypes.sol";
import {NestedSafeApproval, SafeTxEvidence} from "crossecute/messaging/signed/types/SignedDispatchTypes.sol";
import {SafeTx, SignedSafeTx} from "../src/ICrossecuteGuard.sol";
import {SafeHashes} from "../src/SafeHashes.sol";
import {AuthorityUpdate} from "../src/authority/AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "../src/authority/ISourceAuthorityGuard.sol";
import {SourceAuthorityGuard} from "../src/authority/SourceAuthorityGuard.sol";
import {Batch} from "./Batch.sol";
import {SourceAuthorityBase} from "./SourceAuthorityBase.sol";

/// @dev A has owners [A's EOA, B] and B has one EOA owner. Covers the source rules for a Safe
///      owner: named positions must be executed heads, a child's rotation travels as a child
///      update, and the portable set may differ from the executing one.
contract SourceAuthorityNestedTest is SourceAuthorityBase {
    uint256 internal constant KEY_A = 0xA11CE;
    uint256 internal constant KEY_C = 0xC4A5;
    uint256 internal constant KEY_D = 0xD00D;
    address internal constant SENTINEL = address(1);

    Safe internal a;
    Safe internal b;
    bytes32 internal bHead0;

    event AuthorityUpdateExecuted(
        address indexed sourceSafe,
        bytes32 indexed updateHead,
        bytes32 authorityHash,
        bytes portableSignatures,
        NestedSafeApproval[] nestedApprovals
    );

    function setUp() public override {
        super.setUp();
        uint256[] memory keys = new uint256[](1);
        keys[0] = KEY_C;
        b = _guarded(keys, 1);
        _activate(b, _signersOf(KEY_C));
        bHead0 = _head(b);

        address[] memory owners = new address[](2);
        owners[0] = vm.addr(KEY_A);
        owners[1] = address(b);
        a = _newSafe(owners, 2);
        Signer[] memory signers = new Signer[](2);
        signers[0] = _eoa(KEY_A);
        signers[1] = _child(b, _keys(KEY_C));
        _install(a, signers, guard, _permissiveConfig(), true);
    }

    function _keys(uint256 key) internal pure returns (uint256[] memory keys) {
        keys = new uint256[](1);
        keys[0] = key;
    }

    function _signersOf(uint256 key) internal pure returns (Signer[] memory signers) {
        signers = new Signer[](1);
        signers[0] = _eoa(key);
    }

    function _aSigners(uint256 bKey) internal view returns (Signer[] memory signers) {
        signers = new Signer[](2);
        signers[0] = _eoa(KEY_A);
        signers[1] = _child(b, _keys(bKey));
    }

    function _aRecord() internal view returns (SafeAuthorityRecord memory) {
        uint8[] memory kinds = new uint8[](2);
        kinds[0] = a.getOwners()[0] == address(b) ? OWNER_SAFE : OWNER_EOA;
        kinds[1] = a.getOwners()[1] == address(b) ? OWNER_SAFE : OWNER_EOA;
        return _record(a, kinds);
    }

    function _aGraph(SafeAuthorityRecord memory bRecord, bytes32 position)
        internal
        view
        returns (AuthorityGraph memory)
    {
        return _graph(_aRecord(), bRecord, position);
    }

    function _activateA(bytes32 bPosition) internal {
        _activate(a, _aGraph(_record(b), bPosition), _aSigners(KEY_C));
    }

    function _swapC(address owner) internal view returns (Call[] memory mutations) {
        mutations = new Call[](1);
        mutations[0] = _call(address(b), abi.encodeCall(b.swapOwner, (SENTINEL, vm.addr(KEY_C), owner)));
    }

    function _bAfterSwap(uint256 key) internal view returns (AuthorityGraph memory) {
        SafeAuthorityRecord memory record = _record(b);
        record.owners[0] = SafeOwner(vm.addr(key), OWNER_EOA);
        return _graph(record);
    }

    /// @dev B's swap, built but not run, and the evidence it would carry.
    function _bSwap(uint256 fromKey, uint256 toKey) internal view returns (bytes memory data, SafeTxEvidence memory e) {
        AuthorityGraph memory next = _bAfterSwap(toKey);
        data = _ownershipData(b, _head(b), _hash(next), _swapOwner(fromKey, toKey));
        SafeTx memory tx_ = SafeTx(address(multiSend), 0, data, 1, 0, 0, 0, address(0), address(0), b.nonce());
        bytes memory signatures = _sign(_signersOf(fromKey), SafeHashes.transactionHash(tx_, address(b), block.chainid));
        e = SafeTxEvidence(SignedSafeTx(tx_, signatures), new NestedSafeApproval[](0));
    }

    function _swapOwner(uint256 fromKey, uint256 toKey) internal view returns (Call[] memory mutations) {
        mutations = new Call[](1);
        mutations[0] = _call(address(b), abi.encodeCall(b.swapOwner, (SENTINEL, vm.addr(fromKey), vm.addr(toKey))));
    }

    function _runBSwap(uint256 fromKey, uint256 toKey) internal returns (ChildUpdate memory child) {
        (bytes memory data, SafeTxEvidence memory e) = _bSwap(fromKey, toKey);
        AuthorityGraph memory next = _bAfterSwap(toKey);
        _execStaged(
            b, address(multiSend), data, Enum.Operation.DelegateCall, next, new ChildUpdate[](0), _signersOf(fromKey)
        );
        child = ChildUpdate(address(b), e, next.nodes[0].record, AuthorityUpdateEncoding.entries(next));
    }

    function _selectCalls(
        AuthorityGraph memory next,
        ChildUpdate[] memory children,
        bytes memory executing,
        bytes memory portable
    ) internal view returns (Batch.Call[] memory) {
        bytes memory data = abi.encodeCall(
            ISourceAuthorityGuard.selectAuthority, (AuthorityUpdate(_head(a), _hash(next)))
        );
        return _stagedCalls(a, address(guard), data, Enum.Operation.Call, next, children, executing, portable);
    }

    function _selectSig(AuthorityGraph memory next, uint256 bKey) internal view returns (bytes memory) {
        bytes memory data =
            abi.encodeCall(ISourceAuthorityGuard.selectAuthority, (AuthorityUpdate(_head(a), _hash(next))));
        return _sign(_aSigners(bKey), _txHash(a, address(guard), 0, data, Enum.Operation.Call));
    }

    // Activation names executed positions

    function testActivationNamesTheChildsExecutedPosition() public {
        _activateA(bHead0);
        assertEq(guard.selection(address(a)).authorityHash, _hash(_aGraph(_record(b), bHead0)));
    }

    function testActivationRejectsAnUnexecutedPosition() public {
        AuthorityGraph memory graph = _aGraph(_record(b), bytes32(uint256(0xBAD)));
        Batch.Call[] memory calls = _activationCalls(a, graph, _aSigners(KEY_C));
        vm.expectRevert(
            abi.encodeWithSelector(
                SourceAuthorityGuard.PositionNotExecuted.selector, address(b), bytes32(uint256(0xBAD))
            )
        );
        batch.run(calls);
    }

    function testActivationRejectsTheWrongRecordAtAnExecutedPosition() public {
        SafeAuthorityRecord memory wrong = _record(b);
        wrong.owners[0] = SafeOwner(vm.addr(KEY_D), OWNER_EOA);
        Batch.Call[] memory calls = _activationCalls(a, _aGraph(wrong, bHead0), _aSigners(KEY_C));
        vm.expectRevert(abi.encodeWithSelector(SourceAuthorityGuard.PositionNotExecuted.selector, address(b), bHead0));
        batch.run(calls);
    }

    function testActivationNeedsEverySafeOwnerActivated() public {
        uint256[] memory keys = new uint256[](1);
        keys[0] = KEY_D;
        Safe never = _guarded(keys, 1);
        address[] memory owners = new address[](2);
        owners[0] = vm.addr(KEY_A);
        owners[1] = address(never);
        Safe parent = _newSafe(owners, 2);
        Signer[] memory signers = new Signer[](2);
        signers[0] = _eoa(KEY_A);
        signers[1] = _child(never, _keys(KEY_D));
        _install(parent, signers, guard, _permissiveConfig(), true);

        uint8[] memory kinds = new uint8[](2);
        kinds[0] = parent.getOwners()[0] == address(never) ? OWNER_SAFE : OWNER_EOA;
        kinds[1] = parent.getOwners()[1] == address(never) ? OWNER_SAFE : OWNER_EOA;
        Batch.Call[] memory calls =
            _activationCalls(parent, _graph(_record(parent, kinds), _record(never), bytes32(uint256(1))), signers);
        vm.expectRevert(
            abi.encodeWithSelector(
                SourceAuthorityGuard.PositionNotExecuted.selector, address(never), bytes32(uint256(1))
            )
        );
        batch.run(calls);
    }

    // Adopting a child's update

    function testAdoptsAChildRotationOnceItExecuted() public {
        _activateA(bHead0);
        ChildUpdate memory child = _runBSwap(KEY_C, KEY_D);
        bytes32 bHead1 = _head(b);

        AuthorityGraph memory next = _aGraph(_record(b), bHead1);
        ChildUpdate[] memory children = new ChildUpdate[](1);
        children[0] = child;
        // B's new owner votes for B inside A's update, as B's own owners now do on source.
        bytes memory sig = _selectSig(next, KEY_D);
        batch.run(_selectCalls(next, children, sig, sig));
        assertEq(guard.selection(address(a)).authorityHash, _hash(next));
    }

    function testRejectsAChildUpdateThatNeverExecuted() public {
        _activateA(bHead0);
        (, SafeTxEvidence memory e) = _bSwap(KEY_C, KEY_D);
        AuthorityGraph memory bNext = _bAfterSwap(KEY_D);
        ChildUpdate[] memory children = new ChildUpdate[](1);
        children[0] = ChildUpdate(address(b), e, bNext.nodes[0].record, AuthorityUpdateEncoding.entries(bNext));
        bytes32 position = SafeHashes.transactionHash(e.signedSafeTx.safeTx, address(b), block.chainid);

        AuthorityGraph memory next = _aGraph(bNext.nodes[0].record, position);
        bytes memory sig = _selectSig(next, KEY_C);
        Batch.Call[] memory calls = _selectCalls(next, children, sig, sig);
        vm.expectRevert(abi.encodeWithSelector(SourceAuthorityGuard.PositionNotExecuted.selector, address(b), position));
        batch.run(calls);
    }

    function testAdoptingAnEarlierExecutedPositionStillWorksAfterTheChildMovesOn() public {
        _activateA(bHead0);
        ChildUpdate memory first = _runBSwap(KEY_C, KEY_D);
        bytes32 bHead1 = _head(b);
        _runBSwap(KEY_D, KEY_C);

        AuthorityGraph memory next = _aGraph(_record(b), bHead1);
        // _record(b) is B's live record, back at C; the named position's record is D's.
        next.nodes[1].record = first.newRecord;
        ChildUpdate[] memory children = new ChildUpdate[](1);
        children[0] = first;
        bytes memory sig = _selectSig(next, KEY_C);
        // B's live owner is C again, so Safe's check passes with C, and the guard counts D under
        // the named position: the same set cannot satisfy both.
        Batch.Call[] memory calls = _selectCalls(next, children, sig, _selectSig(next, KEY_D));
        batch.run(calls);
        assertEq(guard.selection(address(a)).authorityHash, _hash(next));
    }

    function testRemovedSafeCanBeReaddedAtAnEarlierExecutedPosition() public {
        _activateA(bHead0);
        SafeAuthorityRecord memory oldB = _record(b);
        ChildUpdate memory change = _runBSwap(KEY_C, KEY_D);
        bytes32 bHead1 = _head(b);
        AuthorityGraph memory adopted = _aGraph(_record(b), bHead1);
        ChildUpdate[] memory children = new ChildUpdate[](1);
        children[0] = change;
        bytes memory sig = _selectSig(adopted, KEY_D);
        batch.run(_selectCalls(adopted, children, sig, sig));

        AuthorityGraph memory lower = _aGraph(_record(b), bHead1);
        lower.nodes[0].record.threshold = 1;
        Call[] memory mutations = new Call[](1);
        mutations[0] = _call(address(a), abi.encodeCall(a.changeThreshold, (1)));
        _execOwnershipChange(a, lower, mutations, _aSigners(KEY_D));

        SafeOwner[] memory onlyA = new SafeOwner[](1);
        onlyA[0] = SafeOwner(vm.addr(KEY_A), OWNER_EOA);
        AuthorityGraph memory removed = _graph(SafeAuthorityRecord(address(a), 1, onlyA));
        mutations[0] = _call(address(a), abi.encodeCall(a.removeOwner, (vm.addr(KEY_A), address(b), 1)));
        _execOwnershipChange(a, removed, mutations, _signersOf(KEY_A));

        SafeOwner[] memory restored = new SafeOwner[](2);
        restored[0] = SafeOwner(address(b), OWNER_SAFE);
        restored[1] = SafeOwner(vm.addr(KEY_A), OWNER_EOA);
        AuthorityGraph memory earlier = _graph(SafeAuthorityRecord(address(a), 1, restored), oldB, bHead0);
        mutations[0] = _call(address(a), abi.encodeCall(a.addOwnerWithThreshold, (address(b), 1)));
        _execOwnershipChange(a, earlier, mutations, _signersOf(KEY_A));
        assertEq(guard.selection(address(a)).authorityHash, _hash(earlier));
        assertEq(_head(b), bHead1);
        assertTrue(guard.executed(address(b), bHead0));
    }

    // Two signature sets

    function testPortableSetMayDifferFromTheExecutingSet() public {
        _activateA(bHead0);
        AuthorityGraph memory same = _aGraph(_record(b), bHead0);
        // B's owner C votes before B rotates to D.
        bytes memory portable = _selectSig(same, KEY_C);
        _runBSwap(KEY_C, KEY_D);
        bytes memory executing = _selectSig(same, KEY_D);

        SafeTxEvidence memory evidence;
        evidence.signedSafeTx.safeTx.to = address(guard);
        evidence.signedSafeTx.safeTx.nonce = a.nonce();
        evidence.signedSafeTx.safeTx.data =
            abi.encodeCall(ISourceAuthorityGuard.selectAuthority, (AuthorityUpdate(_head(a), _hash(same))));
        evidence.signedSafeTx.signatures = portable;
        evidence.nestedApprovals = new NestedSafeApproval[](0);
        bytes32 published = keccak256(abi.encode(evidence, same, new ChildUpdate[](0)));
        vm.expectEmit(true, false, false, true, address(guard));
        emit AuthorityUpdateExecuted(address(a), bytes32(0), _hash(same), portable, new NestedSafeApproval[](0));
        batch.run(_selectCalls(same, new ChildUpdate[](0), executing, portable));
        assertEq(guard.selection(address(a)).authorityHash, _hash(same));
        assertEq(guard.publishedAuthority(address(a), _head(a)), published);
        evidence.signedSafeTx.signatures = executing;
        assertTrue(keccak256(abi.encode(evidence, same, new ChildUpdate[](0))) != published);
    }

    function testSourceRejectsWithoutThePreRotationSet() public {
        _activateA(bHead0);
        AuthorityGraph memory same = _aGraph(_record(b), bHead0);
        _runBSwap(KEY_C, KEY_D);
        bytes memory executing = _selectSig(same, KEY_D);

        // The live owners pass Safe's check, but B counts under its stored owners in the portable
        // check, and D is not among them.
        Batch.Call[] memory calls = _selectCalls(same, new ChildUpdate[](0), executing, executing);
        vm.expectRevert(abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, address(b), vm.addr(KEY_D)));
        batch.run(calls);
    }

    function testActivationRejectsEnabledModules() public {
        uint256[] memory keys = new uint256[](1);
        keys[0] = KEY_D;
        address[] memory owners = new address[](1);
        owners[0] = vm.addr(KEY_D);
        Safe withModule = _newSafe(owners, 1);
        Signer[] memory signers = _signersOf(KEY_D);
        _exec(
            withModule,
            signers,
            address(withModule),
            0,
            abi.encodeCall(withModule.enableModule, (address(0xB0B0))),
            Enum.Operation.Call
        );
        _install(withModule, signers, guard, _permissiveConfig(), true);
        Batch.Call[] memory calls = _activationCalls(withModule, _graph(_record(withModule)), signers);
        vm.expectRevert(SourceAuthorityGuard.ModulesEnabled.selector);
        batch.run(calls);
    }
}
