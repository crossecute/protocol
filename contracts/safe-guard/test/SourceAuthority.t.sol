// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {AuthorityGraph} from "crossecute/messaging/authority/AuthorityGraph.sol";
import {ChildUpdate} from "crossecute/messaging/authority/ChildUpdate.sol";
import {Call} from "crossecute/messaging/Call.sol";
import {AuthorityMutations} from "crossecute/messaging/authority/AuthorityMutations.sol";
import {SafeAuthorityRecord, SafeOwner} from "crossecute/messaging/signed/types/SafeAuthorityTypes.sol";
import {NestedSafeApproval} from "crossecute/messaging/signed/types/SignedDispatchTypes.sol";
import {ReceiverAuthority} from "crossecute/messaging/authority/ReceiverAuthority.sol";
import {ICrossecuteGuard} from "../src/ICrossecuteGuard.sol";
import {AuthoritySelection, AuthorityUpdate} from "../src/authority/AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "../src/authority/ISourceAuthorityGuard.sol";
import {SourceAuthorityGuard} from "../src/authority/SourceAuthorityGuard.sol";
import {Batch} from "./Batch.sol";
import {SourceAuthorityBase} from "./SourceAuthorityBase.sol";

/// @dev A staged-selector target that calls the guard back, as a callback during execution would.
contract Stager {
    ISourceAuthorityGuard internal immutable GUARD;

    constructor(ISourceAuthorityGuard guard) {
        GUARD = guard;
    }

    function sendMessage(bytes calldata, bytes calldata, bytes[] calldata) external {
        AuthorityGraph memory graph;
        GUARD.stageUpdate(msg.sender, graph, new ChildUpdate[](0), "", new NestedSafeApproval[](0));
    }
}

contract SourceAuthorityTest is SourceAuthorityBase {
    uint256 internal constant KEY_A = 0xA11CE;
    uint256 internal constant KEY_B = 0xB0B;
    uint256 internal constant KEY_C = 0xC4A5;
    uint256 internal constant KEY_D = 0xD00D;

    Safe internal safe;

    event AuthorityUpdateExecuted(
        address indexed sourceSafe,
        bytes32 indexed updateHead,
        bytes32 authorityHash,
        bytes portableSignatures,
        NestedSafeApproval[] nestedApprovals
    );

    function setUp() public override {
        super.setUp();
        uint256[] memory keys = new uint256[](3);
        (keys[0], keys[1], keys[2]) = (KEY_A, KEY_B, KEY_C);
        safe = _guarded(keys, 2);
    }

    function _ab() internal pure returns (Signer[] memory signers) {
        signers = new Signer[](2);
        signers[0] = _eoa(KEY_A);
        signers[1] = _eoa(KEY_B);
    }

    function _activated() internal returns (bytes32 head) {
        _activate(safe, _ab());
        head = _head(safe);
    }

    // Activation

    function testActivationRecordsLiveStateAsFirstHead() public {
        AuthorityGraph memory graph = _graph(_record(safe));
        bytes32 txHash = _txHash(
            safe, address(guard), 0, abi.encodeCall(ISourceAuthorityGuard.activate, (_hash(graph))), Enum.Operation.Call
        );
        _activate(safe, graph, _ab());

        AuthoritySelection memory selection = guard.selection(address(safe));
        assertEq(selection.updateHead, txHash);
        assertEq(selection.authorityHash, _hash(graph));
        assertTrue(guard.executed(address(safe), txHash));
        assertFalse(guard.executed(address(safe), bytes32(uint256(1))));
    }

    function testActivationEmitsThePortableSet() public {
        AuthorityGraph memory graph = _graph(_record(safe));
        bytes memory data = abi.encodeCall(ISourceAuthorityGuard.activate, (_hash(graph)));
        bytes32 txHash = _txHash(safe, address(guard), 0, data, Enum.Operation.Call);
        bytes memory signatures = _sign(_ab(), txHash);
        vm.expectEmit(true, true, false, true, address(guard));
        emit AuthorityUpdateExecuted(address(safe), txHash, _hash(graph), signatures, new NestedSafeApproval[](0));
        _execStaged(
            safe, address(guard), data, Enum.Operation.Call, graph, new ChildUpdate[](0), signatures, signatures
        );
    }

    function testActivationRequiresStagedGraph() public {
        bytes memory data = abi.encodeCall(ISourceAuthorityGuard.activate, (bytes32(uint256(1))));
        bytes memory signatures = _signFor(safe, _ab(), address(guard), 0, data, Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(SourceAuthorityGuard.NoStagedUpdate.selector, address(safe)));
        _execWith(safe, address(guard), 0, data, Enum.Operation.Call, signatures);
    }

    function testActivationOnlyOnce() public {
        _activated();
        AuthorityGraph memory graph = _graph(_record(safe));
        bytes memory data = abi.encodeCall(ISourceAuthorityGuard.activate, (_hash(graph)));
        bytes memory signatures = _signFor(safe, _ab(), address(guard), 0, data, Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(SourceAuthorityGuard.AlreadyActivated.selector, address(safe)));
        _execStaged(
            safe, address(guard), data, Enum.Operation.Call, graph, new ChildUpdate[](0), signatures, signatures
        );
    }

    function testActivationRejectsGraphThatIsNotTheLiveOwners() public {
        SafeAuthorityRecord memory record = _record(safe);
        record.owners[0].owner = vm.addr(KEY_D);
        Batch.Call[] memory calls = _activationCalls(safe, _graph(record), _ab());
        vm.expectRevert(SourceAuthorityGuard.OwnersMismatch.selector);
        batch.run(calls);

        record = _record(safe);
        record.threshold = 3;
        calls = _activationCalls(safe, _graph(record), _ab());
        vm.expectRevert(ReceiverAuthority.ActivationRootMismatch.selector);
        batch.run(calls);
    }

    function testActivationRejectsQuorumOutsideTheLiveOwners() public {
        Signer[] memory signers = new Signer[](2);
        signers[0] = _eoa(KEY_A);
        signers[1] = _eoa(KEY_D);
        Batch.Call[] memory calls = _activationCalls(safe, _graph(_record(safe)), signers);
        vm.expectRevert("GS026");
        batch.run(calls);
    }

    function testActivationNeedsBothGuardSlots() public {
        address[] memory owners = new address[](1);
        owners[0] = vm.addr(KEY_A);
        Safe txGuardOnly = _newSafe(owners, 1);
        Signer[] memory signers = new Signer[](1);
        signers[0] = _eoa(KEY_A);
        _install(txGuardOnly, signers, guard, _permissiveConfig(), false);
        Batch.Call[] memory calls = _activationCalls(txGuardOnly, _graph(_record(txGuardOnly)), signers);
        vm.expectRevert(
            abi.encodeWithSelector(
                SourceAuthorityGuard.GuardNotInstalled.selector,
                0xb104e0b93118902c651344349b610029d694cfdec91c589c91ebafbcd0289947
            )
        );
        batch.run(calls);
    }

    function _proxy(address implementation, address handler_, uint256 salt)
        internal
        returns (Safe proxy, Signer[] memory signers)
    {
        address[] memory owners = new address[](1);
        owners[0] = vm.addr(KEY_A);
        signers = new Signer[](1);
        signers[0] = _eoa(KEY_A);
        proxy = Safe(
            payable(address(
                    factory.createProxyWithNonce(
                        implementation,
                        abi.encodeCall(
                            Safe.setup, (owners, 1, address(0), "", handler_, address(0), 0, payable(address(0)))
                        ),
                        salt
                    )
                ))
        );
        _install(proxy, signers, guard, _permissiveConfig(), true);
    }

    function testActivationRejectsUnpinnedSingleton() public {
        address other = address(new Safe());
        (Safe proxy, Signer[] memory signers) = _proxy(other, address(handler), 777);
        Batch.Call[] memory calls = _activationCalls(proxy, _graph(_record(proxy)), signers);
        vm.expectRevert(abi.encodeWithSelector(SourceAuthorityGuard.UnrecognizedSingleton.selector, other));
        batch.run(calls);
    }

    function testActivationRejectsUnpinnedHandler() public {
        (Safe proxy, Signer[] memory signers) = _proxy(address(singleton), address(0xBEEF), 778);
        Batch.Call[] memory calls = _activationCalls(proxy, _graph(_record(proxy)), signers);
        vm.expectRevert(abi.encodeWithSelector(SourceAuthorityGuard.UnrecognizedHandler.selector, address(0xBEEF)));
        batch.run(calls);
    }

    function testMarkerCallsRevertOutsideARecognizedTransaction() public {
        _activated();
        vm.expectRevert(abi.encodeWithSelector(SourceAuthorityGuard.UnexpectedAuthorityCall.selector, address(this)));
        guard.activate(bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(SourceAuthorityGuard.UnexpectedAuthorityCall.selector, address(this)));
        guard.selectAuthority(AuthorityUpdate(bytes32(0), bytes32(0)));
        vm.expectRevert(abi.encodeWithSelector(SourceAuthorityGuard.UnexpectedAuthorityCall.selector, address(this)));
        guard.registerOwnershipChange(AuthorityUpdate(bytes32(0), bytes32(0)));
    }

    // Ownership changes

    function _addOwner(address owner, uint256 threshold) internal view returns (Call[] memory mutations) {
        mutations = new Call[](1);
        mutations[0] = _call(address(safe), abi.encodeCall(safe.addOwnerWithThreshold, (owner, threshold)));
    }

    function _withNewOwner(address owner, uint256 threshold) internal view returns (AuthorityGraph memory) {
        SafeAuthorityRecord memory record = _record(safe);
        SafeOwner[] memory owners = new SafeOwner[](record.owners.length + 1);
        owners[0] = SafeOwner(owner, 0);
        for (uint256 i = 0; i < record.owners.length; ++i) {
            owners[i + 1] = record.owners[i];
        }
        record.owners = owners;
        record.threshold = threshold;
        return _graph(record);
    }

    function _changeOwners(address owner, uint256 threshold, Signer[] memory signers)
        internal
        returns (AuthorityGraph memory next)
    {
        next = _withNewOwner(owner, threshold);
        _execStaged(
            safe,
            address(multiSend),
            _ownershipData(safe, _head(safe), _hash(next), _addOwner(owner, threshold)),
            Enum.Operation.DelegateCall,
            next,
            new ChildUpdate[](0),
            signers
        );
    }

    function testOwnershipChangeAdvancesTheHeadAndTheOwners() public {
        bytes32 first = _activated();
        AuthorityGraph memory next = _changeOwners(vm.addr(KEY_D), 3, _ab());

        assertEq(safe.getThreshold(), 3);
        assertTrue(safe.isOwner(vm.addr(KEY_D)));
        AuthoritySelection memory selection = guard.selection(address(safe));
        assertEq(selection.authorityHash, _hash(next));
        assertTrue(selection.updateHead != first);
        assertTrue(guard.executed(address(safe), first));
        assertTrue(guard.executed(address(safe), selection.updateHead));
    }

    function testOwnershipChangeNeedsTheStagedGraph() public {
        _activated();
        AuthorityGraph memory next = _withNewOwner(vm.addr(KEY_D), 2);
        bytes memory data = _ownershipData(safe, _head(safe), _hash(next), _addOwner(vm.addr(KEY_D), 2));
        bytes memory signatures = _signFor(safe, _ab(), address(multiSend), 0, data, Enum.Operation.DelegateCall);
        vm.expectRevert(abi.encodeWithSelector(SourceAuthorityGuard.NoStagedUpdate.selector, address(safe)));
        _execWith(safe, address(multiSend), 0, data, Enum.Operation.DelegateCall, signatures);
    }

    function testOwnershipChangeNeedsActivation() public {
        AuthorityGraph memory next = _withNewOwner(vm.addr(KEY_D), 2);
        bytes memory data = _ownershipData(safe, bytes32(uint256(1)), _hash(next), _addOwner(vm.addr(KEY_D), 2));
        bytes memory signatures = _sign(_ab(), _txHash(safe, address(multiSend), 0, data, Enum.Operation.DelegateCall));
        vm.expectRevert(abi.encodeWithSelector(SourceAuthorityGuard.NotActivated.selector, address(safe)));
        _execStaged(
            safe,
            address(multiSend),
            data,
            Enum.Operation.DelegateCall,
            next,
            new ChildUpdate[](0),
            signatures,
            signatures
        );
    }

    function testOwnershipChangeRejectsWrongPredecessor() public {
        _activated();
        AuthorityGraph memory next = _withNewOwner(vm.addr(KEY_D), 2);
        bytes memory data = _ownershipData(safe, bytes32(uint256(7)), _hash(next), _addOwner(vm.addr(KEY_D), 2));
        bytes memory signatures = _sign(_ab(), _txHash(safe, address(multiSend), 0, data, Enum.Operation.DelegateCall));
        vm.expectRevert(ReceiverAuthority.PreviousUpdateMismatch.selector);
        _execStaged(
            safe,
            address(multiSend),
            data,
            Enum.Operation.DelegateCall,
            next,
            new ChildUpdate[](0),
            signatures,
            signatures
        );
    }

    function testOwnershipChangeRejectsGraphThatIsNotTheMutationResult() public {
        _activated();
        AuthorityGraph memory next = _withNewOwner(vm.addr(KEY_D), 2);
        bytes memory data = _ownershipData(safe, _head(safe), _hash(next), _addOwner(vm.addr(KEY_D), 3));
        bytes memory signatures = _sign(_ab(), _txHash(safe, address(multiSend), 0, data, Enum.Operation.DelegateCall));
        vm.expectRevert(AuthorityMutations.MutationResultMismatch.selector);
        _execStaged(
            safe,
            address(multiSend),
            data,
            Enum.Operation.DelegateCall,
            next,
            new ChildUpdate[](0),
            signatures,
            signatures
        );
    }

    function testNewOwnersCannotSignTheirOwnInstallation() public {
        _activated();
        Signer[] memory signers = new Signer[](2);
        signers[0] = _eoa(KEY_A);
        signers[1] = _eoa(KEY_D);
        AuthorityGraph memory next = _withNewOwner(vm.addr(KEY_D), 2);
        bytes memory data = _ownershipData(safe, _head(safe), _hash(next), _addOwner(vm.addr(KEY_D), 2));
        bytes memory signatures =
            _sign(signers, _txHash(safe, address(multiSend), 0, data, Enum.Operation.DelegateCall));
        vm.expectRevert();
        _execStaged(
            safe,
            address(multiSend),
            data,
            Enum.Operation.DelegateCall,
            next,
            new ChildUpdate[](0),
            signatures,
            signatures
        );
    }

    function testSuccessiveUpdatesLink() public {
        _activated();
        _changeOwners(vm.addr(KEY_D), 2, _ab());
        bytes32 second = _head(safe);

        SafeAuthorityRecord memory record = _record(safe);
        AuthorityGraph memory same = _graph(record);
        _select(safe, same, _ab());
        assertTrue(_head(safe) != second);
        assertTrue(guard.executed(address(safe), second));
        assertEq(guard.selection(address(safe)).authorityHash, _hash(same));
    }

    function testSelectAuthorityCannotChangeTheRootRecord() public {
        _activated();
        AuthorityGraph memory next = _withNewOwner(vm.addr(KEY_D), 2);
        bytes memory data =
            abi.encodeCall(ISourceAuthorityGuard.selectAuthority, (AuthorityUpdate(_head(safe), _hash(next))));
        bytes memory signatures = _sign(_ab(), _txHash(safe, address(guard), 0, data, Enum.Operation.Call));
        vm.expectRevert(ReceiverAuthority.RootRecordMismatch.selector);
        _execStaged(safe, address(guard), data, Enum.Operation.Call, next, new ChildUpdate[](0), signatures, signatures);
    }

    function testStagedDataIsConsumedByOneTransaction() public {
        _activated();
        AuthorityGraph memory same = _graph(_record(safe));
        bytes memory data =
            abi.encodeCall(ISourceAuthorityGuard.selectAuthority, (AuthorityUpdate(_head(safe), _hash(same))));
        bytes memory first = _sign(_ab(), _txHash(safe, address(guard), 0, data, Enum.Operation.Call));
        bytes memory dataTwo =
            abi.encodeCall(ISourceAuthorityGuard.selectAuthority, (AuthorityUpdate(bytes32(uint256(5)), _hash(same))));
        bytes memory second =
            _sign(_ab(), _txHashAt(safe, address(guard), 0, dataTwo, Enum.Operation.Call, safe.nonce() + 1));

        // Both executions in one outer transaction: the second finds nothing staged.
        Batch.Call[] memory calls = new Batch.Call[](3);
        calls[0] = Batch.Call(
            address(guard),
            abi.encodeCall(
                guard.stageUpdate, (address(safe), same, new ChildUpdate[](0), first, new NestedSafeApproval[](0))
            ),
            false
        );
        calls[1] = _executeCall(safe, address(guard), data, Enum.Operation.Call, first);
        calls[2] = _executeCall(safe, address(guard), dataTwo, Enum.Operation.Call, second);
        vm.expectRevert(abi.encodeWithSelector(SourceAuthorityGuard.NoStagedUpdate.selector, address(safe)));
        batch.run(calls);
    }

    function testStagingIsRejectedWhileASafeTransactionIsLive() public {
        Stager stager = new Stager(guard);
        bytes memory data = _sendMessageCall();
        bytes memory signatures = _signFor(safe, _ab(), address(stager), 0, data, Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(SourceAuthorityGuard.SafeBusy.selector, address(safe)));
        _execWith(safe, address(stager), 0, data, Enum.Operation.Call, signatures);
    }

    function _sendMessageCall() internal pure returns (bytes memory) {
        return abi.encodeCall(Stager.sendMessage, (hex"01", hex"02", new bytes[](0)));
    }

    // Protected calls

    function testActivatedSafeCannotCallItself() public {
        _activated();
        bytes memory data = abi.encodeCall(safe.changeThreshold, (1));
        bytes memory signatures = _signFor(safe, _ab(), address(safe), 0, data, Enum.Operation.Call);
        vm.expectRevert(SourceAuthorityGuard.SelfCallDenied.selector);
        _execWith(safe, address(safe), 0, data, Enum.Operation.Call, signatures);
    }

    function testActivatedSafeCannotDelegatecallAnythingElse() public {
        _activated();
        address evil = address(0xE711);
        vm.etch(evil, hex"00");
        bytes memory signatures = _signFor(safe, _ab(), evil, 0, "", Enum.Operation.DelegateCall);
        vm.expectRevert(abi.encodeWithSelector(SourceAuthorityGuard.DelegatecallDenied.selector, evil));
        _execWith(safe, evil, 0, "", Enum.Operation.DelegateCall, signatures);
    }

    function testActivatedSafeCannotReachItselfThroughABatch() public {
        _activated();
        bytes memory batchData = abi.encodeCall(
            multiSend.multiSend, (_multiSendEntry(address(safe), abi.encodeCall(safe.changeThreshold, (1))))
        );
        bytes memory signatures = _signFor(safe, _ab(), address(multiSend), 0, batchData, Enum.Operation.DelegateCall);
        vm.expectRevert(SourceAuthorityGuard.BatchSelfCallDenied.selector);
        _execWith(safe, address(multiSend), 0, batchData, Enum.Operation.DelegateCall, signatures);
    }

    function testActivatedSafeStillCallsOthersAndBatchesThem() public {
        _activated();
        vm.deal(address(safe), 1 ether);
        address recipient = address(0xCAFE);
        assertTrue(_exec(safe, _ab(), recipient, 1, "", Enum.Operation.Call));
        bytes memory batchData = abi.encodeCall(multiSend.multiSend, (_multiSendEntry(recipient, "")));
        assertTrue(_exec(safe, _ab(), address(multiSend), 0, batchData, Enum.Operation.DelegateCall));
        assertEq(guard.selection(address(safe)).authorityHash, _hash(_graph(_record(safe))));
    }

    function testUnactivatedSafeIsUnrestricted() public {
        bytes memory data = abi.encodeCall(safe.changeThreshold, (1));
        assertTrue(_exec(safe, _ab(), address(safe), 0, data, Enum.Operation.Call));
        assertEq(safe.getThreshold(), 1);
    }

    function testGuardAdvertisesTheSourceInterface() public view {
        assertTrue(guard.supportsInterface(type(ISourceAuthorityGuard).interfaceId));
        assertTrue(guard.supportsInterface(type(ICrossecuteGuard).interfaceId));
    }
}
