// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {SafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {ISourceAuthorityGuard} from "@crossecute/safe-guard/authority/ISourceAuthorityGuard.sol";
import {AuthorityUpdate} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {AuthorityGraph} from "src/messaging/authority/AuthorityGraph.sol";
import {AuthorityUpdateEncoding} from "src/messaging/authority/AuthorityUpdateEncoding.sol";
import {AuthorityRecognition} from "src/messaging/authority/AuthorityRecognition.sol";
import {ChildUpdate} from "src/messaging/authority/ChildUpdate.sol";
import {ReceiverAuthority} from "src/messaging/authority/ReceiverAuthority.sol";
import {HyperlaneReceiver} from "src/protocols/hyperlane/HyperlaneReceiver.sol";
import {IReceiverInit, ReceiverBase, ICommitFinalize, ICancel} from "src/messaging/inbound/ReceiverBase.sol";
import {SignedReceiver} from "src/messaging/inbound/SignedReceiver.sol";
import {SignedDispatchCalls} from "src/messaging/signed/SignedDispatchCalls.sol";
import {SafeQuorum} from "src/messaging/signed/SafeQuorum.sol";
import {SafeSignaturesUtils} from "src/messaging/signed/SafeSignaturesUtils.sol";
import {DispatchLeaves} from "src/messaging/signed/DispatchLeaves.sol";
import {ISignedTransmitter} from "src/messaging/outbound/ISignedTransmitter.sol";
import {SafeAuthorityRecord, SafeOwner, OWNER_SAFE} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {
    ExecutionLeaf,
    SafeTxEvidence,
    SignedBootstrap,
    WIRE_STANDALONE,
    WIRE_MERKLE,
    WIRE_AUTHORITY
} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {ISignedReceiver} from "src/messaging/inbound/ISignedReceiver.sol";
import {IERC7786GatewaySource} from "src/messaging/IErc7786.sol";
import {Bytes} from "src/messaging/signed/Bytes.sol";

import {Call} from "src/messaging/Call.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {deployConduit} from "test/DeployProxy.sol";
import {MockHyperlaneMailbox} from "test/protocols/hyperlane/MockHyperlaneMailbox.sol";
import {MerkleBuilder, SafeSigs, Sig, Records} from "test/signed/SignedFixtures.sol";

contract Sink {
    uint256 public hits;
    bytes public last;

    /// @notice Record a successful payload call and its data, accepting attached value.
    /// @dev Tests observe this state to distinguish execution, duplication and rollback.
    function hit(bytes calldata data) external payable {
        ++hits;
        last = data;
    }

    /// @notice Always revert when called.
    /// @dev A predictable failure lets receiver tests verify atomic setup and execution
    ///      rollback.
    function boom() external pure {
        revert("boom");
    }
}

struct LegacySignedBootstrap {
    SafeAuthorityRecord[] records;
    bytes setupCalls;
}

/// @dev The receiver in signed mode (#108): created by the transceiver's two-step arming, then
///      fed hand-built deliveries through its provider and by direct submission.
contract SignedReceiverTest is Test {
    uint32 constant HOME_DOMAIN = 10;
    uint256 constant SOURCE_CHAIN = 10;
    address constant SAFE = address(0x5AFE);
    address constant TRANSMITTER = address(0x7777);

    MockHyperlaneMailbox mailbox = new MockHyperlaneMailbox();
    Sink sink = new Sink();
    address receiver;
    uint256 nonceSeq;

    /// @notice Build the fixture source Safe's 2-of-3 EOA authority record.
    /// @dev All receiver evidence must be checked against one known stored quorum.
    function _records() internal pure returns (SafeAuthorityRecord[] memory) {
        return Records.list(Records.record(SAFE, 2, Records.eoaOwners(Records.pks(1, 2, 3))));
    }

    /// @notice Hash the fixture authority records.
    /// @dev Initialization tests bind the carried authority to the expected signed-address
    ///      commitment.
    function _graph() internal pure returns (bytes32) {
        return Records.graphHash(SOURCE_CHAIN, _records());
    }

    /// @notice Deploy a provider receiver with plain initialization but no setup calls.
    /// @dev Tests can exercise the second signed-initialization step and ensure it is properly
    ///      restricted.
    function _plainReceiver() internal returns (address r) {
        r = deployConduit(
            address(new HyperlaneReceiver(address(mailbox), address(0x1234), address(0x5678))),
            abi.encodeCall(IReceiverInit.initialize, (TRANSMITTER, bytes32(uint256(HOME_DOMAIN)), new Call[](0)))
        );
    }

    /// @notice Encode a receiver address with the current EVM chain ID.
    /// @dev Destination checks need a complete chain-and-contract address rather than a bare
    ///      EVM address.
    function _here(address r) internal view returns (bytes memory) {
        return Erc7930.encodeEvm(block.chainid, r);
    }

    /// @notice Encode one observable sink call carrying the supplied data.
    /// @dev Execution tests can track exactly which authorized batch ran and whether effects
    ///      rolled back.
    function _calls(bytes memory data) internal view returns (bytes memory) {
        Call[] memory c = new Call[](1);
        c[0] = Call(address(sink), 0, abi.encodeCall(Sink.hit, (data)));
        return abi.encode(c);
    }

    /// @notice Sign a source-transmitter call using the selected signer descriptions and a
    ///         fresh Safe nonce.
    /// @dev Each test gets distinct evidence bound to the fixture Safe, source chain and exact
    ///      calldata.
    function _signed(bytes memory data, Sig[] memory sigs) internal returns (SafeTxEvidence memory evidence) {
        evidence.signedSafeTx.safeTx.to = TRANSMITTER;
        evidence.signedSafeTx.safeTx.data = data;
        evidence.signedSafeTx.safeTx.nonce = ++nonceSeq;
        evidence.signedSafeTx.signatures =
            SafeSigs.blob(sigs, SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, SAFE, SOURCE_CHAIN));
    }

    /// @notice Return two authorized source-owner signing keys.
    /// @dev Valid control cases need a quorum that can be reused while individual tests alter
    ///      evidence.
    function _quorum() internal pure returns (Sig[] memory) {
        return SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(3));
    }

    /// @notice Package the fixture's authority records with encoded setup calls.
    function _bootstrapBody(bytes memory setup) internal view returns (bytes memory) {
        return Records.bootstrap(address(0x1234), _records(), setup);
    }

    /// @notice Call signed initialization as the configured parent transceiver.
    /// @dev Ordinary setup helpers must satisfy the caller restriction so tests isolate other
    ///      validation rules.
    function _initialize(address r, bytes memory body) internal {
        SignedReceiver(payable(r)).initializeSigned(SOURCE_CHAIN, SAFE, body);
    }

    /// @notice Deploy and initialize a signed receiver with an observable setup call.
    /// @dev Each test starts with a stored source authority and a known setup effect for replay
    ///      and rollback assertions.
    function setUp() public {
        vm.warp(1_000_000);
        receiver = _plainReceiver();
        _initialize(receiver, _bootstrapBody(_calls("setup")));
    }

    /* ================================ bootstrap ================================= */

    /// @notice Inspect the authority, nonce, setup effects and protected-call access after
    ///         initialization.
    /// @dev Successful setup must establish signed verification state without authorizing the
    ///      transmitter address itself.
    function test_initializationStoresTheAuthorityAndRunsSetup() public view {
        SignedReceiver r = SignedReceiver(payable(receiver));
        assertEq(r.authorityGraph(), _graph());
        assertEq(r.selection().updateHead, bytes32(uint256(1)));
        assertEq(r.nextNonce(), 0);
        assertEq(sink.hits(), 1);
        assertEq(sink.last(), "setup");
        assertEq(keccak256(abi.encode(r.authorityRecords())), keccak256(abi.encode(_records())));
        assertFalse(r.isAuthorizedCaller(TRANSMITTER));
        assertTrue(r.isAuthorizedCaller(receiver));
    }

    function test_bootstrapEncodingStatesItsSizeIncrease() public view {
        bytes memory setup = abi.encode(new Call[](0));
        for (uint256 count = 1; count <= 3; ++count) {
            SafeAuthorityRecord[] memory records = new SafeAuthorityRecord[](count);
            for (uint256 i; i < count; ++i) {
                address sourceSafe = i == 0 ? SAFE : address(uint160(0xB000 + i));
                if (i + 1 == count) {
                    records[i] = _records()[0];
                    records[i].safe = sourceSafe;
                } else {
                    SafeOwner[] memory owners = new SafeOwner[](1);
                    owners[0] = SafeOwner(address(uint160(0xB001 + i)), OWNER_SAFE);
                    records[i] = Records.record(sourceSafe, 1, owners);
                }
            }
            bytes memory legacy = abi.encode(LegacySignedBootstrap(records, setup));
            assertEq(Records.bootstrap(address(0x1234), records, setup).length - legacy.length, 160 + 64 * count);
        }
    }

    function _updateEvidence(SafeTx memory tx_) internal returns (SafeTxEvidence memory) {
        return _updateEvidence(tx_, _quorum());
    }

    function _updateEvidence(SafeTx memory tx_, Sig[] memory sigs) internal returns (SafeTxEvidence memory evidence) {
        tx_.nonce = ++nonceSeq;
        evidence.signedSafeTx.safeTx = tx_;
        evidence.signedSafeTx.signatures = SafeSigs.blob(sigs, SafeHashes.transactionHash(tx_, SAFE, SOURCE_CHAIN));
    }

    function _selectionUpdate(AuthorityGraph memory next) internal returns (SafeTxEvidence memory) {
        bytes32 head = SignedReceiver(payable(receiver)).selection().updateHead;
        if (head == bytes32(0)) head = bytes32(uint256(1));
        return _selectionUpdateAt(head, next);
    }

    function _selectionUpdateAt(bytes32 head, AuthorityGraph memory next) internal returns (SafeTxEvidence memory) {
        SafeTx memory tx_;
        tx_.to = address(0x1234);
        tx_.data = abi.encodeCall(
            ISourceAuthorityGuard.selectAuthority,
            (AuthorityUpdate(head, AuthorityUpdateEncoding.graphHash(SOURCE_CHAIN, next)))
        );
        return _updateEvidence(tx_);
    }

    function _ownerUpdate() internal returns (SafeTxEvidence memory, AuthorityGraph memory) {
        return _ownerSwap(1, 7, _quorum());
    }

    /// @dev Swaps the first owner slot of the fixture record from `fromKey` to `toKey`.
    function _ownerSwap(uint256 fromKey, uint256 toKey, Sig[] memory sigs)
        internal
        returns (SafeTxEvidence memory evidence, AuthorityGraph memory next)
    {
        next = Records.graph(_records());
        next.nodes[0].record.owners[0].owner = vm.addr(toKey);
        Call[] memory mutations = new Call[](1);
        mutations[0] = Call(
            SAFE,
            0,
            abi.encodeWithSignature("swapOwner(address,address,address)", address(1), vm.addr(fromKey), vm.addr(toKey))
        );
        SafeTx memory tx_;
        tx_.to = address(0x5678);
        tx_.operation = 1;
        tx_.data = AuthorityUpdateEncoding.ownershipBatchData(
            address(0x1234),
            SAFE,
            AuthorityUpdate(
                SignedReceiver(payable(receiver)).selection().updateHead,
                AuthorityUpdateEncoding.graphHash(SOURCE_CHAIN, next)
            ),
            mutations
        );
        evidence = _updateEvidence(tx_, sigs);
    }

    function test_anAuthorityUpdateChangesDispatchVerificationAndRejectsReplay() public {
        (SafeTxEvidence memory update, AuthorityGraph memory next) = _ownerUpdate();
        SafeTxEvidence memory oldMessage = _message(_here(receiver), _calls("old"));
        SignedReceiver r = SignedReceiver(payable(receiver));
        r.submitAuthority(update, next, new ChildUpdate[](0));
        assertEq(r.authorityGraph(), AuthorityUpdateEncoding.graphHash(SOURCE_CHAIN, next));
        assertEq(r.selection().updateHead, SafeHashes.transactionHash(update.signedSafeTx.safeTx, SAFE, SOURCE_CHAIN));
        vm.expectRevert(abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, SAFE, vm.addr(1)));
        r.submitMessage(oldMessage);
        vm.expectRevert(ReceiverAuthority.PreviousUpdateMismatch.selector);
        r.submitAuthority(update, next, new ChildUpdate[](0));
        SafeTxEvidence memory fresh = _signed(
            abi.encodeCall(IERC7786GatewaySource.sendMessage, (_here(receiver), _calls("new"), new bytes[](0))),
            SafeSigs.two(SafeSigs.eoa(7), SafeSigs.eoa(3))
        );
        _deliver(abi.encode(WIRE_STANDALONE, fresh));
        r.submitMessage(fresh);
        assertEq(sink.last(), "new");
        assertEq(sink.hits(), 2);
    }

    function testFuzz_authorityProviderAndDirectShareVerificationAndReplay(bool directFirst) public {
        (SafeTxEvidence memory update, AuthorityGraph memory next) = _ownerUpdate();
        bytes memory submission = abi.encode(update, next, new ChildUpdate[](0));
        SignedReceiver r = SignedReceiver(payable(receiver));
        if (directFirst) r.submitAuthority(update, next, new ChildUpdate[](0));
        else _deliver(abi.encode(WIRE_AUTHORITY, submission));
        bytes32 head = r.selection().updateHead;
        _deliver(abi.encode(WIRE_AUTHORITY, submission));
        assertEq(r.selection().updateHead, head);
        vm.expectRevert(ReceiverAuthority.PreviousUpdateMismatch.selector);
        r.submitAuthority(update, next, new ChildUpdate[](0));
        update.signedSafeTx.signatures = hex"01";
        vm.expectRevert(ReceiverAuthority.PreviousUpdateMismatch.selector);
        _deliver(abi.encode(WIRE_AUTHORITY, abi.encode(update, next, new ChildUpdate[](0))));
        assertEq(r.selection().updateHead, head);
    }

    function test_providerRejectsInvalidAuthorityAtomically() public {
        (SafeTxEvidence memory update, AuthorityGraph memory next) = _ownerUpdate();
        bytes memory valid = abi.encode(update, next, new ChildUpdate[](0));
        update.signedSafeTx.signatures = hex"01";
        vm.expectRevert();
        _deliver(abi.encode(WIRE_AUTHORITY, abi.encode(update, next, new ChildUpdate[](0))));
        assertEq(SignedReceiver(payable(receiver)).selection().updateHead, bytes32(uint256(1)));
        _deliver(abi.encode(WIRE_AUTHORITY, valid));
    }

    enum AuthorityFault {
        WrongHelper,
        WrongGuard,
        UnknownSelector,
        NonzeroValue,
        WrongOperation,
        WrongSourceChain,
        WrongSourceSafe,
        ChangedGraph,
        ProposedOwnerSignature,
        RepeatedSigner,
        ShortSignatures,
        ApprovedHash,
        EoaContractSignature,
        MissingSigner
    }

    function _faultyAuthority(SafeTxEvidence memory update, AuthorityGraph memory next, AuthorityFault fault)
        private
        returns (SafeTxEvidence memory, bytes4 errorSelector)
    {
        SafeTx memory tx_ = update.signedSafeTx.safeTx;
        if (fault == AuthorityFault.WrongHelper) {
            tx_.to = address(0x5679);
            errorSelector = AuthorityRecognition.NotAnAuthorityCall.selector;
        } else if (fault == AuthorityFault.WrongGuard) {
            (AuthorityUpdate memory change, Call[] memory mutations) =
                AuthorityUpdateEncoding.decodeOwnershipBatch(address(0x1234), SAFE, tx_.data);
            tx_.data = AuthorityUpdateEncoding.ownershipBatchData(address(0x1235), SAFE, change, mutations);
            errorSelector = AuthorityUpdateEncoding.InvalidOwnershipBatch.selector;
        } else if (fault == AuthorityFault.UnknownSelector) {
            tx_.to = address(0x1234);
            tx_.operation = 0;
            tx_.data = hex"deadbeef";
            errorSelector = AuthorityRecognition.UnknownGuardSelector.selector;
        } else if (fault == AuthorityFault.NonzeroValue) {
            tx_.value = 1;
            errorSelector = AuthorityRecognition.NotAnAuthorityCall.selector;
        } else if (fault == AuthorityFault.WrongOperation) {
            tx_.operation = 0;
            errorSelector = AuthorityRecognition.NotAnAuthorityCall.selector;
        }
        update = _updateEvidence(tx_);
        bytes32 hash = SafeHashes.transactionHash(update.signedSafeTx.safeTx, SAFE, SOURCE_CHAIN);
        if (fault == AuthorityFault.WrongSourceChain || fault == AuthorityFault.WrongSourceSafe) {
            hash = SafeHashes.transactionHash(
                update.signedSafeTx.safeTx,
                fault == AuthorityFault.WrongSourceSafe ? address(0x5AFF) : SAFE,
                fault == AuthorityFault.WrongSourceChain ? SOURCE_CHAIN + 1 : SOURCE_CHAIN
            );
            update.signedSafeTx.signatures = SafeSigs.blob(_quorum(), hash);
            errorSelector = SafeQuorum.NotAnOwner.selector;
        } else if (fault == AuthorityFault.ChangedGraph) {
            next.nodes[0].record.threshold = 1;
            errorSelector = ReceiverAuthority.ReplacementHashMismatch.selector;
        } else if (fault == AuthorityFault.ProposedOwnerSignature) {
            update.signedSafeTx.signatures = SafeSigs.blob(SafeSigs.two(SafeSigs.eoa(7), SafeSigs.eoa(3)), hash);
            errorSelector = SafeQuorum.NotAnOwner.selector;
        } else if (fault == AuthorityFault.RepeatedSigner) {
            update.signedSafeTx.signatures = SafeSigs.blob(SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(1)), hash);
            errorSelector = SafeQuorum.SignersNotAscending.selector;
        } else if (fault == AuthorityFault.ShortSignatures) {
            update.signedSafeTx.signatures = hex"01";
            errorSelector = SafeSignaturesUtils.SignaturesTooShort.selector;
        } else if (fault == AuthorityFault.ApprovedHash) {
            update.signedSafeTx.signatures[64] = 0x01;
            errorSelector = SafeSignaturesUtils.ApprovedHashUnsupported.selector;
        } else if (fault == AuthorityFault.EoaContractSignature) {
            update.signedSafeTx.signatures =
                SafeSigs.blob(SafeSigs.two(SafeSigs.nested(vm.addr(1), hex"01"), SafeSigs.eoa(3)), hash);
            errorSelector = SafeQuorum.NotAnOwner.selector;
        } else if (fault == AuthorityFault.MissingSigner) {
            update.signedSafeTx.signatures = SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(1)), hash);
            errorSelector = SafeSignaturesUtils.SignaturesTooShort.selector;
        }
        return (update, errorSelector);
    }

    function _submitAuthorityRoute(uint256 route, SafeTxEvidence memory update, AuthorityGraph memory next) private {
        if (route == 0) {
            SignedReceiver(payable(receiver)).submitAuthority(update, next, new ChildUpdate[](0));
        } else if (route == 1) {
            _deliver(abi.encode(WIRE_AUTHORITY, abi.encode(update, next, new ChildUpdate[](0))));
        } else {
            bytes[] memory submissions = new bytes[](1);
            submissions[0] = abi.encode(update, next, new ChildUpdate[](0));
            SignedReceiver(payable(receiver)).submitAuthorityBatch(submissions);
        }
    }

    function test_authorityFaultsRejectAcrossAllSubmissionRoutes() public {
        uint256 snapshot = vm.snapshotState();
        for (uint256 fault = 0; fault <= uint256(type(AuthorityFault).max); ++fault) {
            for (uint256 route = 0; route < 3; ++route) {
                emit log_named_uint("authority fault", fault);
                emit log_named_uint("submission route", route);
                _checkAuthorityFault(AuthorityFault(fault), route);
                assertTrue(vm.revertToState(snapshot));
            }
        }
        assertTrue(vm.deleteStateSnapshot(snapshot));
    }

    function _checkAuthorityFault(AuthorityFault fault, uint256 route) private {
        (SafeTxEvidence memory valid, AuthorityGraph memory next) = _ownerUpdate();
        bytes memory validSubmission = abi.encode(valid, next, new ChildUpdate[](0));
        bytes32 validGraph = AuthorityUpdateEncoding.graphHash(SOURCE_CHAIN, next);
        SafeTxEvidence memory invalid = abi.decode(abi.encode(valid), (SafeTxEvidence));
        bytes4 errorSelector;
        (invalid, errorSelector) = _faultyAuthority(invalid, next, fault);
        vm.expectPartialRevert(errorSelector);
        _submitAuthorityRoute(route, invalid, next);

        SignedReceiver r = SignedReceiver(payable(receiver));
        assertEq(r.selection().updateHead, bytes32(uint256(1)));
        assertEq(r.authorityGraph(), _graph());
        assertEq(keccak256(abi.encode(r.authorityRecords())), keccak256(abi.encode(_records())));
        assertEq(r.nextNonce(), 0);
        assertEq(sink.hits(), 1);
        vm.expectRevert(ReceiverAuthority.GraphNotCached.selector);
        r.graph(validGraph);
        bytes32 rejectedRecord = AuthorityUpdateEncoding.recordHash(next.nodes[0].record);
        vm.expectRevert(ReceiverAuthority.RecordNotCached.selector);
        r.record(rejectedRecord);

        _deliver(abi.encode(WIRE_AUTHORITY, validSubmission));
        assertEq(r.authorityGraph(), validGraph);
        assertEq(r.selection().updateHead, SafeHashes.transactionHash(valid.signedSafeTx.safeTx, SAFE, SOURCE_CHAIN));
    }

    function test_bootstrapHeadAloneDoesNotAuthenticateAuthorityRetry() public {
        AuthorityGraph memory next = Records.graph(_records());
        SafeTxEvidence memory update = _selectionUpdate(next);
        bytes32 head = SafeHashes.transactionHash(update.signedSafeTx.safeTx, SAFE, SOURCE_CHAIN);
        receiver = _plainReceiver();
        _initialize(
            receiver, abi.encode(SignedBootstrap(address(0x1234), head, abi.encode(next), abi.encode(new Call[](0))))
        );
        vm.expectRevert(ReceiverAuthority.PreviousUpdateMismatch.selector);
        _deliver(abi.encode(WIRE_AUTHORITY, abi.encode(update, next, new ChildUpdate[](0))));
    }

    function test_providerRejectsOlderAcceptedUpdatesAfterAdvancing() public {
        AuthorityGraph memory next = Records.graph(_records());
        SafeTxEvidence memory first = _selectionUpdate(next);
        bytes memory old = abi.encode(WIRE_AUTHORITY, abi.encode(first, next, new ChildUpdate[](0)));
        _deliver(old);
        SafeTxEvidence memory second = _selectionUpdate(next);
        _deliver(abi.encode(WIRE_AUTHORITY, abi.encode(second, next, new ChildUpdate[](0))));
        vm.expectRevert(ReceiverAuthority.PreviousUpdateMismatch.selector);
        _deliver(old);
    }

    function test_batchCatchUpSharesProviderReplayState() public {
        AuthorityGraph memory graph = Records.graph(_records());
        SafeTxEvidence memory first = _selectionUpdate(graph);
        SafeTxEvidence memory second =
            _selectionUpdateAt(SafeHashes.transactionHash(first.signedSafeTx.safeTx, SAFE, SOURCE_CHAIN), graph);
        bytes[] memory submissions = new bytes[](2);
        submissions[0] = abi.encode(first, graph, new ChildUpdate[](0));
        submissions[1] = abi.encode(second, graph, new ChildUpdate[](0));
        SignedReceiver r = SignedReceiver(payable(receiver));
        emit log_named_uint(
            "authorityReceiverBatchTwoSelectionCalldataBytes",
            abi.encodeCall(SignedReceiver.submitAuthorityBatch, (submissions)).length
        );
        uint256 g = gasleft();
        r.submitAuthorityBatch(submissions);
        emit log_named_uint("authorityReceiverBatchTwoSelectionGas", g - gasleft());
        bytes32 head = SafeHashes.transactionHash(second.signedSafeTx.safeTx, SAFE, SOURCE_CHAIN);
        assertEq(r.selection().updateHead, head);
        _deliver(abi.encode(WIRE_AUTHORITY, submissions[1]));
        vm.expectRevert(ReceiverAuthority.PreviousUpdateMismatch.selector);
        r.submitAuthority(second, graph, new ChildUpdate[](0));
        vm.expectRevert(ReceiverAuthority.PreviousUpdateMismatch.selector);
        _deliver(abi.encode(WIRE_AUTHORITY, submissions[0]));
        assertEq(r.selection().updateHead, head);
    }

    /// @dev T18: running out of gas partway through verification or storage leaves no partial
    ///      authority, cache or replay state on any route, and the same submission then applies.
    function test_outOfGasAuthoritySubmissionLeavesNoPartialState() public {
        (SafeTxEvidence memory first, AuthorityGraph memory rotated) = _ownerUpdate();
        bytes32 rotatedHash = AuthorityUpdateEncoding.graphHash(SOURCE_CHAIN, rotated);
        SafeTx memory tx_;
        tx_.to = address(0x1234);
        tx_.data = abi.encodeCall(
            ISourceAuthorityGuard.selectAuthority,
            (AuthorityUpdate(SafeHashes.transactionHash(first.signedSafeTx.safeTx, SAFE, SOURCE_CHAIN), rotatedHash))
        );
        SafeTxEvidence memory second = _updateEvidence(tx_, SafeSigs.two(SafeSigs.eoa(7), SafeSigs.eoa(3)));
        bytes[] memory submissions = new bytes[](2);
        submissions[0] = abi.encode(first, rotated, new ChildUpdate[](0));
        submissions[1] = abi.encode(second, rotated, new ChildUpdate[](0));
        bytes32 secondHead = SafeHashes.transactionHash(second.signedSafeTx.safeTx, SAFE, SOURCE_CHAIN);

        bytes[3] memory calls = [
            abi.encodeCall(SignedReceiver.submitAuthority, (first, rotated, new ChildUpdate[](0))),
            abi.encodeCall(
                HyperlaneReceiver.handle,
                (HOME_DOMAIN, bytes32(uint256(uint160(TRANSMITTER))), abi.encode(WIRE_AUTHORITY, submissions[0]))
            ),
            abi.encodeCall(SignedReceiver.submitAuthorityBatch, (submissions))
        ];
        bytes32 firstHead = SafeHashes.transactionHash(first.signedSafeTx.safeTx, SAFE, SOURCE_CHAIN);
        bytes32 recordHash = AuthorityUpdateEncoding.recordHash(rotated.nodes[0].record);
        for (uint256 route; route < 3; ++route) {
            _checkOutOfGas(
                calls[route],
                route == 1 ? address(mailbox) : address(this),
                rotatedHash,
                recordHash,
                route == 2 ? secondHead : firstHead
            );
        }
    }

    function _checkOutOfGas(bytes memory data, address caller, bytes32 graphHash, bytes32 recordHash, bytes32 head)
        private
    {
        SignedReceiver r = SignedReceiver(payable(receiver));
        uint256 snapshot = vm.snapshotState();
        vm.prank(caller);
        uint256 g = gasleft();
        (bool ok,) = receiver.call(data);
        uint256 used = g - gasleft();
        assertTrue(ok);
        assertTrue(vm.revertToState(snapshot));
        for (uint256 part = 1; part < 16; part += 2) {
            vm.prank(caller);
            // forge-lint: disable-next-line(return-bomb) the callee is the receiver under test
            (ok,) = receiver.call{gas: used * part / 16}(data);
            assertFalse(ok);
            assertEq(r.selection().updateHead, bytes32(uint256(1)));
            assertEq(r.authorityGraph(), _graph());
            vm.expectRevert(ReceiverAuthority.GraphNotCached.selector);
            r.graph(graphHash);
            vm.expectRevert(ReceiverAuthority.RecordNotCached.selector);
            r.record(recordHash);
        }
        vm.prank(caller);
        (ok,) = receiver.call(data);
        assertTrue(ok);
        assertEq(r.authorityGraph(), graphHash);
        assertEq(r.selection().updateHead, head);
        assertTrue(vm.revertToState(snapshot));
    }

    function test_measureAuthorityReceiverOwnerRotation() public {
        (SafeTxEvidence memory update, AuthorityGraph memory next) = _ownerUpdate();
        bytes memory submission = abi.encode(update, next, new ChildUpdate[](0));
        emit log_named_uint(
            "authorityReceiverDirectCalldataBytes",
            abi.encodeCall(SignedReceiver.submitAuthority, (update, next, new ChildUpdate[](0))).length
        );
        uint256 g = gasleft();
        SignedReceiver(payable(receiver)).submitAuthority(update, next, new ChildUpdate[](0));
        emit log_named_uint("authorityReceiverOwnerRotationGas", g - gasleft());
        assertEq(submission.length + 96, abi.encode(WIRE_AUTHORITY, submission).length);
    }

    function test_aThresholdUpdateUsesTheOldQuorumAndChangesFutureQuorums() public {
        AuthorityGraph memory next = Records.graph(_records());
        next.nodes[0].record.threshold = 3;
        Call[] memory mutations = new Call[](1);
        mutations[0] = Call(SAFE, 0, abi.encodeWithSignature("changeThreshold(uint256)", 3));
        SafeTx memory tx_;
        tx_.to = address(0x5678);
        tx_.operation = 1;
        tx_.data = AuthorityUpdateEncoding.ownershipBatchData(
            address(0x1234),
            SAFE,
            AuthorityUpdate(bytes32(uint256(1)), AuthorityUpdateEncoding.graphHash(SOURCE_CHAIN, next)),
            mutations
        );
        SignedReceiver r = SignedReceiver(payable(receiver));
        r.submitAuthority(_updateEvidence(tx_), next, new ChildUpdate[](0));
        vm.expectRevert();
        r.submitMessage(_message(_here(receiver), _calls("two")));
        Sig[] memory signers = new Sig[](3);
        (signers[0], signers[1], signers[2]) = (SafeSigs.eoa(1), SafeSigs.eoa(2), SafeSigs.eoa(3));
        r.submitMessage(
            _signed(
                abi.encodeCall(IERC7786GatewaySource.sendMessage, (_here(receiver), _calls("three"), new bytes[](0))),
                signers
            )
        );
        assertEq(sink.last(), "three");
    }

    function test_anAcceptedCommitmentSurvivesAnAuthorityChange() public {
        Call[] memory deferred = abi.decode(_calls("deferred"), (Call[]));
        Call[] memory commit = new Call[](1);
        commit[0] = Call(receiver, 0, abi.encodeCall(ICommitFinalize.commit, (Commitment.hashCalls(deferred))));
        ISignedReceiver(receiver).submitMessage(_message(_here(receiver), abi.encode(commit)));
        (SafeTxEvidence memory update, AuthorityGraph memory next) = _ownerUpdate();
        SignedReceiver(payable(receiver)).submitAuthority(update, next, new ChildUpdate[](0));
        vm.prank(vm.addr(1));
        ICommitFinalize(receiver).finalize(deferred);
        assertEq(sink.last(), "deferred");
    }

    function testFuzz_commitmentRepeatCancelAndConsumptionSurviveRotation(bool cancel) public {
        Call[] memory deferred = abi.decode(_calls("retained"), (Call[]));
        bytes32 commitment = Commitment.hashCalls(deferred);
        Call[] memory commit = new Call[](1);
        commit[0] = Call(receiver, 0, abi.encodeCall(ICommitFinalize.commit, (commitment)));
        ISignedReceiver(receiver).submitMessage(_message(_here(receiver), abi.encode(commit)));
        ISignedReceiver(receiver).submitMessage(_message(_here(receiver), abi.encode(commit)));
        ReceiverBase base = ReceiverBase(payable(receiver));
        assertEq(base.outstanding(commitment), 2);
        (SafeTxEvidence memory update, AuthorityGraph memory next) = _ownerUpdate();
        SignedReceiver(payable(receiver)).submitAuthority(update, next, new ChildUpdate[](0));
        assertEq(base.outstanding(commitment), 2);
        if (cancel) {
            Call[] memory calls = new Call[](1);
            calls[0] = Call(receiver, 0, abi.encodeCall(ICancel.cancel, (commitment)));
            ISignedReceiver(receiver)
                .submitMessage(
                    _signed(
                        abi.encodeCall(
                            IERC7786GatewaySource.sendMessage, (_here(receiver), abi.encode(calls), new bytes[](0))
                        ),
                        SafeSigs.two(SafeSigs.eoa(7), SafeSigs.eoa(3))
                    )
                );
        } else {
            vm.prank(vm.addr(1));
            base.finalize(deferred);
            assertEq(base.outstanding(commitment), 1);
            vm.prank(vm.addr(1));
            base.finalize(deferred);
        }
        assertEq(base.outstanding(commitment), 0);
        vm.expectRevert(ReceiverBase.CommitmentMismatch.selector);
        base.finalize(deferred);
    }

    /// @dev T22: a retry authenticates under the selected graph before the replay record answers.
    function test_messageRetriesReverifyUnderTheSelectedGraph() public {
        SafeTxEvidence memory kept = _signed(
            abi.encodeCall(IERC7786GatewaySource.sendMessage, (_here(receiver), _calls("kept"), new bytes[](0))),
            SafeSigs.two(SafeSigs.eoa(2), SafeSigs.eoa(3))
        );
        SafeTxEvidence memory retired = _message(_here(receiver), _calls("retired"));
        ISignedReceiver(receiver).submitMessage(kept);
        ISignedReceiver(receiver).submitMessage(retired);
        (SafeTxEvidence memory update, AuthorityGraph memory next) = _ownerUpdate();
        SignedReceiver(payable(receiver)).submitAuthority(update, next, new ChildUpdate[](0));

        vm.recordLogs();
        _deliver(abi.encode(WIRE_STANDALONE, kept));
        ISignedReceiver(receiver).submitMessage(kept);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].topics[0], ISignedReceiver.DuplicateMessage.selector);
        assertEq(logs[1].topics[0], ISignedReceiver.DuplicateMessage.selector);

        vm.expectRevert(abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, SAFE, vm.addr(1)));
        _deliver(abi.encode(WIRE_STANDALONE, retired));
        vm.expectRevert(abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, SAFE, vm.addr(1)));
        ISignedReceiver(receiver).submitMessage(retired);
        assertEq(sink.hits(), 3);
    }

    /// @dev T22: the leaf nonce and its execution records carry across an authority change; a root
    ///      signed by the removed owner stops authorizing, including repeats of executed leaves.
    function test_leafOrderAndExecutionRecordsSurviveAnAuthorityChange() public {
        ExecutionLeaf memory l0 = _leaf(0, _calls("a"));
        ExecutionLeaf memory l1 = _leaf(1, _calls("b"));
        (SafeTxEvidence memory oldRoot, bytes32[][] memory p) = _register(_two(l0, l1));
        SignedReceiver r = SignedReceiver(payable(receiver));
        ISignedReceiver(receiver).submitLeaf(oldRoot, l0, p[0]);
        bytes32 executed = r.executionAt(0);
        (SafeTxEvidence memory update, AuthorityGraph memory next) = _ownerUpdate();
        r.submitAuthority(update, next, new ChildUpdate[](0));

        vm.expectRevert(abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, SAFE, vm.addr(1)));
        ISignedReceiver(receiver).submitLeaf(oldRoot, l1, p[1]);
        vm.expectRevert(abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, SAFE, vm.addr(1)));
        _deliver(abi.encode(WIRE_MERKLE, oldRoot, l0, p[0]));

        ExecutionLeaf memory conflicting = _leaf(0, _calls("c"));
        (SafeTxEvidence memory newRoot, bytes32[][] memory q) =
            _register(_two(conflicting, l1), SafeSigs.two(SafeSigs.eoa(7), SafeSigs.eoa(3)));
        vm.expectRevert(abi.encodeWithSelector(SignedReceiver.ConflictingLeaf.selector, 0));
        ISignedReceiver(receiver).submitLeaf(newRoot, conflicting, q[0]);
        _deliver(abi.encode(WIRE_MERKLE, newRoot, l1, q[1]));
        assertEq(r.nextNonce(), 2);
        assertEq(r.executionAt(0), executed);
        assertEq(sink.last(), "b");
        assertEq(sink.hits(), 3);
    }

    /// @dev T22: a return to the earlier owners revives their unexecuted approvals but never
    ///      re-runs executed or cancelled work.
    function test_returningToEarlierOwnersRevivesOnlyUnconsumedApprovals() public {
        Call[] memory deferred = abi.decode(_calls("deferred"), (Call[]));
        bytes32 commitment = Commitment.hashCalls(deferred);
        Call[] memory commit = new Call[](1);
        commit[0] = Call(receiver, 0, abi.encodeCall(ICommitFinalize.commit, (commitment)));
        Call[] memory cancel = new Call[](1);
        cancel[0] = Call(receiver, 0, abi.encodeCall(ICancel.cancel, (commitment)));
        SafeTxEvidence memory committed = _message(_here(receiver), abi.encode(commit));
        SafeTxEvidence memory cancelled = _message(_here(receiver), abi.encode(cancel));
        SafeTxEvidence memory pending = _message(_here(receiver), _calls("pending"));
        ISignedReceiver(receiver).submitMessage(committed);
        ISignedReceiver(receiver).submitMessage(cancelled);

        SignedReceiver r = SignedReceiver(payable(receiver));
        (SafeTxEvidence memory away, AuthorityGraph memory rotated) = _ownerUpdate();
        r.submitAuthority(away, rotated, new ChildUpdate[](0));
        vm.expectRevert(abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, SAFE, vm.addr(1)));
        r.submitMessage(pending);
        (SafeTxEvidence memory back, AuthorityGraph memory original) =
            _ownerSwap(7, 1, SafeSigs.two(SafeSigs.eoa(7), SafeSigs.eoa(3)));
        r.submitAuthority(back, original, new ChildUpdate[](0));
        assertEq(r.authorityGraph(), _graph());
        assertTrue(r.selection().updateHead != bytes32(uint256(1)));

        r.submitMessage(pending);
        assertEq(sink.last(), "pending");
        vm.recordLogs();
        r.submitMessage(committed);
        _deliver(abi.encode(WIRE_STANDALONE, cancelled));
        assertEq(vm.getRecordedLogs().length, 2);
        assertEq(ReceiverBase(payable(receiver)).outstanding(commitment), 0);
        vm.expectRevert(ReceiverBase.CommitmentMismatch.selector);
        ReceiverBase(payable(receiver)).finalize(deferred);
        assertEq(sink.hits(), 2);
    }

    function test_bootstrapRejectsTheWrongGuardOrZeroHead() public {
        address r = _plainReceiver();
        SignedBootstrap memory bootstrap = abi.decode(_bootstrapBody(_calls("x")), (SignedBootstrap));
        bootstrap.guard = address(0xBAD);
        vm.expectRevert(ReceiverAuthority.BootstrapGuardMismatch.selector);
        _initialize(r, abi.encode(bootstrap));
        bootstrap.guard = address(0x1234);
        bootstrap.updateHead = bytes32(0);
        vm.expectRevert(ReceiverAuthority.ZeroCommitment.selector);
        _initialize(r, abi.encode(bootstrap));
        assertEq(SignedReceiver(payable(r)).authorityGraph(), bytes32(0));
    }

    function test_unsetPinsAllowPlainModeButRefuseSignedInitialization() public {
        address r = deployConduit(
            address(new HyperlaneReceiver(address(mailbox), address(0), address(0))),
            abi.encodeCall(IReceiverInit.initialize, (TRANSMITTER, bytes32(uint256(HOME_DOMAIN)), new Call[](0)))
        );
        assertTrue(SignedReceiver(payable(r)).isAuthorizedCaller(TRANSMITTER));
        vm.expectRevert(SignedReceiver.AuthorityPinsUnset.selector);
        _initialize(r, _bootstrapBody(_calls("x")));
    }

    function test_anActivationCannotResetReceiverAuthority() public {
        SafeTx memory tx_;
        tx_.to = address(0x1234);
        tx_.data = abi.encodeCall(ISourceAuthorityGuard.activate, (_graph()));
        vm.expectRevert(ReceiverAuthority.ActivationNotAccepted.selector);
        SignedReceiver(payable(receiver))
            .submitAuthority(_updateEvidence(tx_), Records.graph(_records()), new ChildUpdate[](0));
    }

    /// @notice Attempt signed initialization from an unrelated caller.
    /// @dev Only the transceiver that created the receiver may establish its authority
    ///      snapshot.
    function test_onlyTheParentTransceiverInitializes() public {
        address r = _plainReceiver();
        bytes memory body = _bootstrapBody(_calls("x"));
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(SignedReceiver.NotParentTransceiver.selector, address(0xBAD)));
        SignedReceiver(payable(r)).initializeSigned(SOURCE_CHAIN, SAFE, body);
    }

    /// @notice Initialize with records rooted at a Safe other than the conduit's owner.
    /// @dev The stored authority must be the owner's.
    function test_recordsRootedAtAnotherSafeRefuse() public {
        address r = _plainReceiver();
        bytes memory body = _bootstrapBody(_calls("x"));
        vm.expectRevert(abi.encodeWithSelector(ReceiverAuthority.RootIsNotOwner.selector, address(0x1), SAFE));
        SignedReceiver(payable(r)).initializeSigned(SOURCE_CHAIN, address(0x1), body);
    }

    /// @notice Initialize with records no signature supports.
    /// @dev The receiver takes the carried graph on the provider's authentication; signatures
    ///      could not prove the owners who did not sign, so none are checked.
    function test_theCarriedRecordsAreStoredWithoutSignatures() public {
        address r = _plainReceiver();
        SafeAuthorityRecord[] memory other =
            Records.list(Records.record(SAFE, 1, Records.eoaOwners(Records.pks(7, 8, 9))));
        _initialize(r, Records.bootstrap(address(0x1234), other, _calls("x")));
        assertEq(keccak256(abi.encode(SignedReceiver(payable(r)).authorityRecords())), keccak256(abi.encode(other)));
    }

    /// @notice Initialize with a graph that fails the canonical checks.
    /// @dev Shape validation still applies to the carried records.
    function test_aMalformedGraphRefuses() public {
        address r = _plainReceiver();
        SafeAuthorityRecord[] memory bad =
            Records.list(Records.record(SAFE, 0, Records.eoaOwners(Records.pks(1, 2, 3))));
        vm.expectRevert();
        _initialize(r, Records.bootstrap(address(0x1234), bad, _calls("x")));
        assertEq(SignedReceiver(payable(r)).authorityGraph(), bytes32(0));
    }

    /// @notice Make the setup batch fail during signed initialization.
    /// @dev A receiver must not remain partially initialized when authorized setup cannot
    ///      complete.
    function test_aRevertingSetupRevertsInitialization() public {
        address r = _plainReceiver();
        Call[] memory c = new Call[](1);
        c[0] = Call(address(sink), 0, abi.encodeCall(Sink.boom, ()));
        vm.expectPartialRevert(bytes4(keccak256("CallFailed(uint256,bytes)")));
        _initialize(r, _bootstrapBody(abi.encode(c)));
    }

    /// @notice Call signed initialization again on an initialized receiver.
    /// @dev Stored authority must not be overwritten through the creation entry point.
    function test_aSecondInitializationRefuses() public {
        bytes memory body = _bootstrapBody(_calls("x"));
        vm.expectRevert(SignedReceiver.AlreadySigned.selector);
        _initialize(receiver, body);
    }

    /* ================================ standalone ================================ */

    /// @notice Build signed `sendMessage` evidence for a recipient and encoded calls.
    /// @dev Standalone tests need the same source-call shape the receiver decodes in
    ///      production.
    function _message(bytes memory recipient, bytes memory calls) internal returns (SafeTxEvidence memory) {
        return _signed(abi.encodeCall(IERC7786GatewaySource.sendMessage, (recipient, calls, new bytes[](0))), _quorum());
    }

    /// @notice Deliver a wire payload through the mock provider using the expected origin and
    ///         transmitter.
    /// @dev This exercises provider authentication before the shared signed-message verifier.
    function _deliver(bytes memory wire) internal {
        vm.prank(address(mailbox));
        HyperlaneReceiver(payable(receiver)).handle(HOME_DOMAIN, bytes32(uint256(uint160(TRANSMITTER))), wire);
    }

    /// @notice Deliver the same standalone authorization through provider and direct routes.
    /// @dev Both entry paths must share replay tracking so changing transport cannot repeat
    ///      execution.
    function test_aStandaloneMessageRunsOnceAcrossBothRoutes() public {
        SafeTxEvidence memory evidence = _message(_here(receiver), _calls("m"));
        ISignedReceiver(receiver).submitMessage{value: 1}(evidence);
        assertEq(sink.hits(), 2);
        assertEq(receiver.balance, 1);

        vm.recordLogs();
        _deliver(abi.encode(WIRE_STANDALONE, evidence));
        assertEq(sink.hits(), 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], ISignedReceiver.DuplicateMessage.selector);
    }

    /// @notice Submit a signed standalone send naming another receiver.
    /// @dev Correct signatures must not override destination binding.
    function test_aStandaloneMessageForAnotherRecipientRefuses() public {
        bytes memory elsewhere = Erc7930.encodeEvm(block.chainid, address(0xD00D));
        SafeTxEvidence memory evidence = _message(elsewhere, _calls("m"));
        vm.expectRevert(abi.encodeWithSelector(SignedDispatchCalls.WrongDestination.selector, elsewhere));
        ISignedReceiver(receiver).submitMessage(evidence);
    }

    /// @notice Change signed calldata or point the transaction at another source target.
    /// @dev The receiver must verify the exact authorized transaction and expected transmitter.
    function test_alteredCalldataOrAnotherTargetRefuses() public {
        SafeTxEvidence memory evidence = _message(_here(receiver), _calls("m"));
        evidence.signedSafeTx.safeTx.data =
            abi.encodeCall(IERC7786GatewaySource.sendMessage, (_here(receiver), _calls("n"), new bytes[](0)));
        vm.expectPartialRevert(SafeQuorum.NotAnOwner.selector);
        ISignedReceiver(receiver).submitMessage(evidence);

        evidence = _message(_here(receiver), _calls("m"));
        evidence.signedSafeTx.safeTx.to = address(0x8888);
        vm.expectRevert(abi.encodeWithSelector(SignedDispatchCalls.NotSourceCall.selector, TRANSMITTER));
        ISignedReceiver(receiver).submitMessage(evidence);
    }

    /// @notice Try an incorrect provider sender, then submit the valid evidence directly.
    /// @dev Provider authentication and signature authorization are separate; a rejected
    ///      transport must not consume valid direct evidence.
    function test_aProviderWithTheWrongSenderRefusesAndDirectSubmissionStillWorks() public {
        SafeTxEvidence memory evidence = _message(_here(receiver), _calls("m"));
        vm.prank(address(mailbox));
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        HyperlaneReceiver(payable(receiver))
            .handle(HOME_DOMAIN, bytes32(uint256(0xBAD)), abi.encode(WIRE_STANDALONE, evidence));
        assertEq(sink.hits(), 1);
        ISignedReceiver(receiver).submitMessage(evidence);
        assertEq(sink.hits(), 2);
    }

    /// @notice Deliver an unsigned plain payload to a signed receiver.
    /// @dev The signed mode must not fall back to trusting the source transmitter's address
    ///      alone.
    function test_aPlainPayloadFromTheProviderRefuses() public {
        vm.expectRevert(abi.encodeWithSelector(SignedReceiver.UnknownWire.selector, 32));
        _deliver(_calls("plain"));
    }

    /* =================================== leaves ================================= */

    /// @notice Build an execution leaf with selected calls and nonce for this receiver.
    /// @dev Leaf tests can vary ordering or payload while retaining a valid destination and
    ///      window.
    function _leaf(uint256 nonce, bytes memory calls) internal view returns (ExecutionLeaf memory leaf) {
        leaf.destination = _here(receiver);
        leaf.nonce = nonce;
        leaf.validAfter = block.timestamp;
        leaf.deadline = block.timestamp + 1 days;
        leaf.calls = calls;
        leaf.attributes = new bytes[](0);
    }

    /// @notice Build a tree, sign its root registration and return proofs for every leaf.
    /// @dev Receiver tests need independently generated membership evidence without requiring a
    ///      source registration transaction.
    function _register(ExecutionLeaf[] memory leaves) internal returns (SafeTxEvidence memory, bytes32[][] memory) {
        return _register(leaves, _quorum());
    }

    function _register(ExecutionLeaf[] memory leaves, Sig[] memory sigs)
        internal
        returns (SafeTxEvidence memory evidence, bytes32[][] memory proofs)
    {
        bytes32[] memory hashes = new bytes32[](leaves.length);
        for (uint256 i; i < leaves.length; ++i) {
            hashes[i] = DispatchLeaves.hash(leaves[i]);
        }
        proofs = new bytes32[][](leaves.length);
        for (uint256 i; i < leaves.length; ++i) {
            proofs[i] = MerkleBuilder.proof(hashes, i);
        }
        evidence = _signed(abi.encodeCall(ISignedTransmitter.registerRoot, (MerkleBuilder.root(hashes))), sigs);
    }

    /// @notice Wrap a single execution leaf in an array.
    /// @dev One-leaf cases can use the same registration and proof helpers as multi-leaf
    ///      batches.
    function _one(ExecutionLeaf memory a) internal pure returns (ExecutionLeaf[] memory l) {
        l = new ExecutionLeaf[](1);
        l[0] = a;
    }

    /// @notice Build a two-leaf execution array in the supplied order.
    /// @dev Tests can express ordered, conflicting and replacement batches with explicit nonce
    ///      choices.
    function _two(ExecutionLeaf memory a, ExecutionLeaf memory b) internal pure returns (ExecutionLeaf[] memory l) {
        l = new ExecutionLeaf[](2);
        (l[0], l[1]) = (a, b);
    }

    /// @notice Attach nonzero transaction value to signed root registration evidence on both
    ///         delivery routes.
    /// @dev The nonpayable source call rule must also apply when destinations verify
    ///      authorization directly.
    function test_aValueBearingRegistrationCannotAuthorizeALeaf() public {
        ExecutionLeaf memory leaf = _leaf(0, _calls("nonpayable"));
        (SafeTxEvidence memory evidence, bytes32[][] memory proofs) = _register(_one(leaf));
        evidence.signedSafeTx.safeTx.value = 1;
        evidence.signedSafeTx.signatures =
            SafeSigs.blob(_quorum(), SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, SAFE, SOURCE_CHAIN));

        vm.expectRevert(abi.encodeWithSelector(SignedDispatchCalls.NonzeroRegistrationValue.selector, 1));
        ISignedReceiver(receiver).submitLeaf(evidence, leaf, proofs[0]);
        vm.expectRevert(abi.encodeWithSelector(SignedDispatchCalls.NonzeroRegistrationValue.selector, 1));
        _deliver(abi.encode(WIRE_MERKLE, evidence, leaf, proofs[0]));
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 0);
        assertEq(sink.hits(), 1);
    }

    /// @notice Deliver leaves out of order and then in order through different routes.
    /// @dev The local execution sequence must hold regardless of how each leaf arrives.
    function test_leavesRunInLocalNonceOrderAcrossRoutes() public {
        ExecutionLeaf memory l0 = _leaf(0, _calls("0"));
        ExecutionLeaf memory l1 = _leaf(1, _calls("1"));
        (SafeTxEvidence memory evidence, bytes32[][] memory p) = _register(_two(l0, l1));

        vm.expectRevert(abi.encodeWithSelector(SignedReceiver.NonceNotNext.selector, 1, 0));
        ISignedReceiver(receiver).submitLeaf(evidence, l1, p[1]);

        _deliver(abi.encode(WIRE_MERKLE, evidence, l0, p[0]));
        ISignedReceiver(receiver).submitLeaf(evidence, l1, p[1]);
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 2);
        assertEq(sink.hits(), 3);
    }

    /// @notice Resubmit an executed batch after expiry and with changed delivery attributes.
    /// @dev Authenticated retries must be harmless acknowledgments rather than new execution or
    ///      timing failures.
    function test_anExecutedLeafRepeatsSilentlyEvenPastItsDeadlineAndUnderNewAttributes() public {
        ExecutionLeaf memory l0 = _leaf(0, _calls("0"));
        (SafeTxEvidence memory evidence, bytes32[][] memory p) = _register(_one(l0));
        ISignedReceiver(receiver).submitLeaf(evidence, l0, p[0]);

        ExecutionLeaf memory reattributed = _leaf(0, _calls("0"));
        reattributed.attributes = new bytes[](1);
        reattributed.attributes[0] = hex"01";
        (SafeTxEvidence memory replacementEvidence, bytes32[][] memory p2) = _register(_one(reattributed));

        vm.warp(l0.deadline + 1);
        vm.recordLogs();
        ISignedReceiver(receiver).submitLeaf{value: 5}(replacementEvidence, reattributed, p2[0]);
        _deliver(abi.encode(WIRE_MERKLE, evidence, l0, p[0]));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(sink.hits(), 2);
        assertEq(receiver.balance, 5);
    }

    /// @notice Submit a different batch at a nonce that has already executed.
    /// @dev Replay tracking must reject conflicting authorization instead of treating it as a
    ///      valid repeat.
    function test_aConflictingLeafAtAConsumedNonceRefuses() public {
        (SafeTxEvidence memory evidence, bytes32[][] memory p) =
            _register(_two(_leaf(0, _calls("a")), _leaf(0, _calls("b"))));
        ISignedReceiver(receiver).submitLeaf(evidence, _leaf(0, _calls("a")), p[0]);
        vm.expectRevert(abi.encodeWithSelector(SignedReceiver.ConflictingLeaf.selector, 0));
        ISignedReceiver(receiver).submitLeaf(evidence, _leaf(0, _calls("b")), p[1]);
    }

    /// @notice Execute leaves at the exact start and deadline boundaries.
    /// @dev Relayers need the signed validity window to have consistent inclusive endpoint
    ///      behavior.
    function test_windowEndpointsAreInclusive() public {
        ExecutionLeaf memory l0 = _leaf(0, _calls("0"));
        l0.validAfter = block.timestamp + 10;
        l0.deadline = block.timestamp + 20;
        (SafeTxEvidence memory evidence, bytes32[][] memory p) = _register(_one(l0));

        vm.warp(l0.validAfter - 1);
        vm.expectRevert(abi.encodeWithSelector(SignedDispatchCalls.WindowClosed.selector, l0.validAfter, l0.deadline));
        ISignedReceiver(receiver).submitLeaf(evidence, l0, p[0]);

        vm.warp(l0.deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(SignedDispatchCalls.WindowClosed.selector, l0.validAfter, l0.deadline));
        ISignedReceiver(receiver).submitLeaf(evidence, l0, p[0]);
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 0);

        vm.warp(l0.deadline);
        ISignedReceiver(receiver).submitLeaf(evidence, l0, p[0]);
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 1);
    }

    /// @notice Execute an empty authorized batch at the next nonce.
    /// @dev An explicit replacement can consume an ordering position without making payload
    ///      calls.
    function test_anEmptyReplacementLeafAdvancesTheNonce() public {
        (SafeTxEvidence memory evidence, bytes32[][] memory p) = _register(_one(_leaf(0, abi.encode(new Call[](0)))));
        ISignedReceiver(receiver).submitLeaf(evidence, _leaf(0, abi.encode(new Call[](0))), p[0]);
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 1);
        assertEq(sink.hits(), 1);
    }

    /// @notice Fail leaf execution and retry after removing the cause.
    /// @dev A failed batch must not consume its nonce or replay slot permanently.
    function test_aFailingLeafRollsBackAndCanBeRetried() public {
        Call[] memory c = new Call[](1);
        c[0] = Call(address(sink), 0, abi.encodeCall(Sink.boom, ()));
        ExecutionLeaf memory l0 = _leaf(0, abi.encode(c));
        (SafeTxEvidence memory evidence, bytes32[][] memory p) = _register(_one(l0));
        vm.expectPartialRevert(bytes4(keccak256("CallFailed(uint256,bytes)")));
        ISignedReceiver(receiver).submitLeaf(evidence, l0, p[0]);
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 0);
        assertEq(SignedReceiver(payable(receiver)).executionAt(0), bytes32(0));
    }

    /// @notice Pass standalone signed-send evidence where root registration is required.
    /// @dev Different source-call selectors must not be interchangeable authorizations.
    function test_aStandaloneAuthorizationIsNotARootRegistration() public {
        ExecutionLeaf memory l0 = _leaf(0, _calls("0"));
        SafeTxEvidence memory evidence = _message(_here(receiver), _calls("m"));
        vm.expectRevert(abi.encodeWithSelector(Bytes.WrongSelector.selector, ISignedTransmitter.registerRoot.selector));
        ISignedReceiver(receiver).submitLeaf(evidence, l0, new bytes32[](0));
    }

    /// @notice Change a leaf or give it membership evidence for a different root.
    /// @dev Signature validity cannot compensate for an invalid Merkle commitment.
    function test_anAlteredLeafOrAProofUnderAnotherRootRefuses() public {
        ExecutionLeaf memory l0 = _leaf(0, _calls("0"));
        (SafeTxEvidence memory evidence, bytes32[][] memory p) = _register(_one(l0));
        ExecutionLeaf memory altered = _leaf(0, _calls("1"));
        vm.expectRevert(DispatchLeaves.InvalidProof.selector);
        ISignedReceiver(receiver).submitLeaf(evidence, altered, p[0]);
        // Repeat after execution still authenticates first.
        ISignedReceiver(receiver).submitLeaf(evidence, l0, p[0]);
        vm.expectRevert(DispatchLeaves.InvalidProof.selector);
        ISignedReceiver(receiver).submitLeaf(evidence, altered, p[0]);
    }

    /* ============================ protected self-calls =========================== */

    /// @notice Call protected receiver operations as the source transmitter.
    /// @dev Signed mode must derive authority from verified execution rather than
    ///      sender-address impersonation.
    function test_theTransmitterAddressGrantsNothing() public {
        vm.startPrank(TRANSMITTER);
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        ICommitFinalize(receiver).commit(keccak256("c"));
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        ICancel(receiver).cancel(keccak256("c"));
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        ReceiverBase(payable(receiver)).revokeGateway(address(mailbox));
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        ReceiverBase(payable(receiver)).execute(new Call[](1));
        vm.stopPrank();
    }

    /// @notice Execute a signed commitment and finalize its batch afterward.
    /// @dev Deferred payload execution must coexist with ordered authorization and receiver
    ///      self-call access rules.
    function test_aCommitOnlyLeafAdvancesTheNonceAndFinalizesLater() public {
        Call[] memory later = new Call[](1);
        later[0] = Call(address(sink), 0, abi.encodeCall(Sink.hit, ("later")));
        bytes32 commitment = Commitment.hashCalls(later);
        Call[] memory commitCall = new Call[](1);
        commitCall[0] = Call(receiver, 0, abi.encodeCall(ICommitFinalize.commit, (commitment)));

        ExecutionLeaf memory l0 = _leaf(0, abi.encode(commitCall));
        ExecutionLeaf memory l1 = _leaf(1, _calls("1"));
        (SafeTxEvidence memory evidence, bytes32[][] memory p) = _register(_two(l0, l1));
        ISignedReceiver(receiver).submitLeaf(evidence, l0, p[0]);
        assertTrue(ReceiverBase(payable(receiver)).isCommitted(commitment));
        ISignedReceiver(receiver).submitLeaf(evidence, l1, p[1]);

        ICommitFinalize(receiver).finalize(later);
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 2);
        assertEq(sink.last(), "later");
    }

    /// @notice Execute gateway revocation, then compare provider delivery with direct
    ///         submission.
    /// @dev Revoking a transport must stop that transport without disabling independent signed
    ///      authorization.
    function test_aSignedRevokeStopsTheProviderAndLeavesDirectSubmission() public {
        Call[] memory revoke = new Call[](1);
        revoke[0] = Call(receiver, 0, abi.encodeCall(ReceiverBase.revokeGateway, (address(mailbox))));
        ISignedReceiver(receiver).submitMessage(_message(_here(receiver), abi.encode(revoke)));

        SafeTxEvidence memory evidence = _message(_here(receiver), _calls("m"));
        vm.expectRevert();
        _deliver(abi.encode(WIRE_STANDALONE, evidence));
        ISignedReceiver(receiver).submitMessage(evidence);
        assertEq(sink.hits(), 2);
    }

    /// @notice Call the signed submission API on a plain receiver.
    /// @dev Mode-specific entry points must not install or assume an authority snapshot that
    ///      was never initialized.
    function test_aPlainReceiverRefusesSignedSubmission() public {
        address r = _plainReceiver();
        SafeTxEvidence memory evidence = _message(_here(r), _calls("m"));
        vm.expectRevert(SignedReceiver.NotSigned.selector);
        ISignedReceiver(r).submitMessage(evidence);
    }
    bytes private reentryCall;
    bool private reentryAttempted;
    bool private reentryAsProvider;

    /// @notice Attempt the selected nested receiver call and assert the shared lock rejects it.
    /// @dev An executing payload can call back into the receiver, so reentrancy protection must
    ///      be tested from inside execution.
    function attemptReentry() external {
        require(msg.sender == receiver);
        reentryAttempted = true;
        if (reentryAsProvider) vm.prank(address(mailbox));
        (bool ok, bytes memory reason) = receiver.call(reentryCall);
        assertFalse(ok, "nested dispatch succeeded");
        assertEq(reason, abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
    }

    /// @notice Exercise each direct and provider route against nested message, leaf and
    ///         finalization entry.
    /// @dev A lock that protects only one route would leave cross-route reentrancy available.
    function test_reentrancyAcrossAllSignedEntryRoutes() public {
        for (uint256 outer; outer < 6; ++outer) {
            for (uint256 inner; inner < 6; ++inner) {
                _reentryScenario(outer, inner);
            }
        }
    }

    /// @notice Execute one outer/inner route combination and retry its refused nested message
    ///         afterward.
    /// @dev Reentrancy rejection must preserve both the outer operation and the future
    ///      usability of unexecuted evidence.
    function _reentryScenario(uint256 outer, uint256 inner) private {
        if (outer == 5) receiver = _plainReceiver();
        uint256 nonce = SignedReceiver(payable(receiver)).nextNonce();
        SafeTxEvidence memory nestedMessageEvidence = _message(_here(receiver), _calls("nested"));
        ExecutionLeaf memory nestedLeaf = _leaf(nonce + 1, _calls("nested leaf"));
        (SafeTxEvidence memory nestedRegistrationEvidence, bytes32[][] memory nestedProof) = _register(_one(nestedLeaf));
        reentryAsProvider = inner == 4;
        if (inner == 0) {
            reentryCall = abi.encodeCall(ISignedReceiver.submitMessage, (nestedMessageEvidence));
        } else if (inner == 1) {
            reentryCall =
                abi.encodeCall(ISignedReceiver.submitLeaf, (nestedRegistrationEvidence, nestedLeaf, nestedProof[0]));
        } else if (inner == 2) {
            reentryCall = abi.encodeWithSignature("finalize((address,uint256,bytes)[])", new Call[](0));
        } else {
            AuthorityGraph memory next = Records.graph(_records());
            SafeTxEvidence memory update = _selectionUpdate(next);
            if (reentryAsProvider) {
                reentryCall = abi.encodeCall(
                    HyperlaneReceiver.handle,
                    (
                        HOME_DOMAIN,
                        bytes32(uint256(uint160(TRANSMITTER))),
                        abi.encode(WIRE_AUTHORITY, abi.encode(update, next, new ChildUpdate[](0)))
                    )
                );
            } else if (inner == 5) {
                bytes[] memory submissions = new bytes[](1);
                submissions[0] = abi.encode(update, next, new ChildUpdate[](0));
                reentryCall = abi.encodeCall(SignedReceiver.submitAuthorityBatch, (submissions));
            } else {
                reentryCall = abi.encodeCall(SignedReceiver.submitAuthority, (update, next, new ChildUpdate[](0)));
            }
        }
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(this), 0, abi.encodeCall(this.attemptReentry, ()));
        reentryAttempted = false;
        if (outer < 2) {
            SafeTxEvidence memory evidence = _message(_here(receiver), abi.encode(calls));
            if (outer == 0) ISignedReceiver(receiver).submitMessage(evidence);
            else _deliver(abi.encode(WIRE_STANDALONE, evidence));
        } else if (outer < 4) {
            ExecutionLeaf memory leaf = _leaf(nonce, abi.encode(calls));
            (SafeTxEvidence memory evidence, bytes32[][] memory proof) = _register(_one(leaf));
            if (outer == 2) ISignedReceiver(receiver).submitLeaf(evidence, leaf, proof[0]);
            else _deliver(abi.encode(WIRE_MERKLE, evidence, leaf, proof[0]));
        } else if (outer == 4) {
            Call[] memory commit = new Call[](1);
            commit[0] = Call(receiver, 0, abi.encodeCall(ICommitFinalize.commit, (Commitment.hashCalls(calls))));
            ISignedReceiver(receiver).submitMessage(_message(_here(receiver), abi.encode(commit)));
            ICommitFinalize(receiver).finalize(calls);
        } else {
            _initialize(receiver, _bootstrapBody(abi.encode(calls)));
        }
        assertTrue(reentryAttempted);
        uint256 before = sink.hits();
        // A refused nested message remains usable after the outer lock is released.
        ISignedReceiver(receiver).submitMessage(nestedMessageEvidence);
        assertEq(sink.hits(), before + 1);
    }

    /// @notice Run a batch with a successful prefix followed by an unfunded transfer, then fund
    ///         and retry.
    /// @dev Failure must roll back earlier effects and nonce state, while later duplication
    ///      must not repeat the successful retry.
    function test_failedValueTransferRollsBackLeafAndEarlierCallsThenRetriesOnce() public {
        Call[] memory calls = new Call[](2);
        calls[0] = Call(address(sink), 0, abi.encodeCall(Sink.hit, ("prefix")));
        calls[1] = Call(address(sink), 1, abi.encodeCall(Sink.hit, ("paid")));
        ExecutionLeaf memory leaf = _leaf(0, abi.encode(calls));
        (SafeTxEvidence memory evidence, bytes32[][] memory proof) = _register(_one(leaf));
        vm.expectPartialRevert(bytes4(keccak256("CallFailed(uint256,bytes)")));
        _deliver(abi.encode(WIRE_MERKLE, evidence, leaf, proof[0]));
        assertEq(sink.hits(), 1, "prefix rolled back");
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 0);
        assertEq(SignedReceiver(payable(receiver)).executionAt(0), bytes32(0));
        ISignedReceiver(receiver).submitLeaf{value: 1}(evidence, leaf, proof[0]);
        assertEq(sink.hits(), 3);
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 1);
        _deliver(abi.encode(WIRE_MERKLE, evidence, leaf, proof[0]));
        assertEq(sink.hits(), 3);
    }

    /// @notice Fail an unfunded standalone execution and retry through the provider after
    ///         funding.
    /// @dev Both routes must share a digest that is recorded only when execution succeeds.
    function test_failedStandaloneTransferLeavesDigestRetryableAcrossRoutes() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(sink), 1, abi.encodeCall(Sink.hit, ("paid")));
        SafeTxEvidence memory evidence = _message(_here(receiver), abi.encode(calls));
        bytes32 digest = SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, SAFE, SOURCE_CHAIN);
        vm.expectPartialRevert(bytes4(keccak256("CallFailed(uint256,bytes)")));
        ISignedReceiver(receiver).submitMessage(evidence);
        assertFalse(SignedReceiver(payable(receiver)).isMessageExecuted(digest));
        vm.deal(receiver, 1);
        _deliver(abi.encode(WIRE_STANDALONE, evidence));
        assertTrue(SignedReceiver(payable(receiver)).isMessageExecuted(digest));
        assertEq(sink.hits(), 2);
        ISignedReceiver(receiver).submitMessage(evidence);
        assertEq(sink.hits(), 2);
    }
}
