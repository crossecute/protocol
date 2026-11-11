// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {HyperlaneReceiver} from "src/protocols/hyperlane/HyperlaneReceiver.sol";
import {IReceiverInit, ReceiverBase, ICommitFinalize, ICancel} from "src/messaging/inbound/ReceiverBase.sol";
import {SignedReceiver} from "src/messaging/inbound/SignedReceiver.sol";
import {SignedDispatchCalls} from "src/messaging/signed/SignedDispatchCalls.sol";
import {SafeAuthority} from "src/messaging/signed/SafeAuthority.sol";
import {DispatchLeaves} from "src/messaging/signed/DispatchLeaves.sol";
import {SafeAuthorityGraph} from "src/messaging/signed/SafeAuthorityGraph.sol";
import {ISignedTransmitter} from "src/messaging/outbound/ISignedTransmitter.sol";
import {SafeAuthorityRecord} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {
    ExecutionLeaf,
    BootstrapLeaf,
    SafeTxEvidence,
    SignedBootstrap,
    WIRE_STANDALONE,
    WIRE_MERKLE
} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {ISignedReceiver} from "src/messaging/inbound/ISignedReceiver.sol";
import {IERC7786GatewaySource} from "src/messaging/IErc7786.sol";
import {Slices} from "src/messaging/signed/Slices.sol";

import {Call} from "src/messaging/Call.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {deployConduit} from "test/DeployProxy.sol";
import {MockHyperlaneMailbox} from "test/protocols/hyperlane/MockHyperlaneMailbox.sol";
import {MerkleBuilder, SafeSigs, Sig, Records} from "test/signed/SignedFixtures.sol";

contract Sink {
    uint256 public hits;
    bytes public last;

    function hit(bytes calldata data) external payable {
        ++hits;
        last = data;
    }

    function boom() external pure {
        revert("boom");
    }
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

    function _records() internal pure returns (SafeAuthorityRecord[] memory) {
        return Records.list(Records.record(SAFE, 2, Records.eoaOwners(Records.pks(1, 2, 3))));
    }

    function _graph() internal pure returns (bytes32) {
        return SafeAuthorityGraph.hash(_records());
    }

    function _plainReceiver() internal returns (address r) {
        r = deployConduit(
            address(new HyperlaneReceiver(address(mailbox))),
            abi.encodeCall(IReceiverInit.initialize, (TRANSMITTER, bytes32(uint256(HOME_DOMAIN)), new Call[](0)))
        );
    }

    function _here(address r) internal view returns (bytes memory) {
        return Erc7930.encodeEvm(block.chainid, r);
    }

    function _calls(bytes memory data) internal view returns (bytes memory) {
        Call[] memory c = new Call[](1);
        c[0] = Call(address(sink), 0, abi.encodeCall(Sink.hit, (data)));
        return abi.encode(c);
    }

    function _signed(bytes memory data, Sig[] memory sigs) internal returns (SafeTxEvidence memory evidence) {
        evidence.signedSafeTx.safeTx.to = TRANSMITTER;
        evidence.signedSafeTx.safeTx.data = data;
        evidence.signedSafeTx.safeTx.nonce = ++nonceSeq;
        evidence.signedSafeTx.signatures =
            SafeSigs.blob(sigs, SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, SAFE, SOURCE_CHAIN));
    }

    function _quorum() internal pure returns (Sig[] memory) {
        return SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(3));
    }

    function _bootstrapLeaf(address r, bytes memory setup) internal view returns (BootstrapLeaf memory) {
        return BootstrapLeaf(_here(r), block.timestamp, block.timestamp + 1 days, setup);
    }

    function _bootstrapBody(BootstrapLeaf memory leaf, Sig[] memory sigs) internal returns (bytes memory) {
        bytes32 leafHash = DispatchLeaves.hash(leaf);
        bytes memory payload = abi.encode(leafHash, uint256(0), leaf, new bytes32[](0));
        SafeTxEvidence memory evidence =
            _signed(abi.encodeCall(ISignedTransmitter.bootstrap, (payload, new bytes[](0))), sigs);
        return abi.encode(SignedBootstrap(evidence, _records()));
    }

    function _initialize(address r, bytes memory body) internal {
        SignedReceiver(payable(r)).initializeSigned(SOURCE_CHAIN, SAFE, _graph(), body);
    }

    function setUp() public {
        vm.warp(1_000_000);
        receiver = _plainReceiver();
        _initialize(receiver, _bootstrapBody(_bootstrapLeaf(receiver, _calls("setup")), _quorum()));
    }

    /* ================================ bootstrap ================================= */

    function test_initializationStoresTheAuthorityAndRunsSetup() public view {
        SignedReceiver r = SignedReceiver(payable(receiver));
        assertEq(r.authorityGraph(), _graph());
        assertEq(r.nextNonce(), 0);
        assertEq(sink.hits(), 1);
        assertEq(sink.last(), "setup");
        assertEq(keccak256(abi.encode(r.authorityRecords())), keccak256(abi.encode(_records())));
        assertFalse(r.isAuthorizedCaller(TRANSMITTER));
        assertTrue(r.isAuthorizedCaller(receiver));
    }

    function test_onlyTheParentTransceiverInitializes() public {
        address r = _plainReceiver();
        bytes memory body = _bootstrapBody(_bootstrapLeaf(r, _calls("x")), _quorum());
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(SignedReceiver.NotParentTransceiver.selector, address(0xBAD)));
        SignedReceiver(payable(r)).initializeSigned(SOURCE_CHAIN, SAFE, _graph(), body);
    }

    function test_substitutedRecordsOrAnotherOwnerRefuse() public {
        address r = _plainReceiver();
        bytes memory body = _bootstrapBody(_bootstrapLeaf(r, _calls("x")), _quorum());
        vm.expectRevert(
            abi.encodeWithSelector(SignedReceiver.AuthorityGraphMismatch.selector, keccak256("g"), _graph())
        );
        SignedReceiver(payable(r)).initializeSigned(SOURCE_CHAIN, SAFE, keccak256("g"), body);

        vm.expectRevert(abi.encodeWithSelector(SignedReceiver.RootIsNotOwner.selector, address(0x1), SAFE));
        SignedReceiver(payable(r)).initializeSigned(SOURCE_CHAIN, address(0x1), _graph(), body);
    }

    function test_aBootstrapForAnotherReceiverRefuses() public {
        address r = _plainReceiver();
        bytes memory body = _bootstrapBody(_bootstrapLeaf(receiver, _calls("x")), _quorum());
        vm.expectRevert(abi.encodeWithSelector(SignedDispatchCalls.WrongDestination.selector, _here(receiver)));
        _initialize(r, body);
    }

    function test_aBootstrapWithoutQuorumRefuses() public {
        address r = _plainReceiver();
        bytes memory body = _bootstrapBody(_bootstrapLeaf(r, _calls("x")), SafeSigs.one(SafeSigs.eoa(1)));
        vm.expectPartialRevert(bytes4(keccak256("SignaturesTooShort(address)")));
        _initialize(r, body);
    }

    function test_anEarlyExpiredOrInvertedBootstrapWindowRefuses() public {
        address r = _plainReceiver();
        BootstrapLeaf memory leaf = _bootstrapLeaf(r, _calls("x"));
        leaf.validAfter = block.timestamp + 1;
        vm.expectRevert(
            abi.encodeWithSelector(SignedDispatchCalls.WindowClosed.selector, leaf.validAfter, leaf.deadline)
        );
        _initialize(r, _bootstrapBody(leaf, _quorum()));

        leaf = _bootstrapLeaf(r, _calls("x"));
        leaf.validAfter = block.timestamp - 10;
        leaf.deadline = block.timestamp - 1;
        vm.expectRevert(
            abi.encodeWithSelector(SignedDispatchCalls.WindowClosed.selector, leaf.validAfter, leaf.deadline)
        );
        _initialize(r, _bootstrapBody(leaf, _quorum()));
    }

    function test_aRevertingSetupRevertsInitialization() public {
        address r = _plainReceiver();
        Call[] memory c = new Call[](1);
        c[0] = Call(address(sink), 0, abi.encodeCall(Sink.boom, ()));
        vm.expectPartialRevert(bytes4(keccak256("CallFailed(uint256,bytes)")));
        _initialize(r, _bootstrapBody(_bootstrapLeaf(r, abi.encode(c)), _quorum()));
    }

    function test_aDelegatecallBootstrapRefuses() public {
        address r = _plainReceiver();
        BootstrapLeaf memory leaf = _bootstrapLeaf(r, _calls("x"));
        bytes memory payload = abi.encode(DispatchLeaves.hash(leaf), uint256(0), leaf, new bytes32[](0));
        SafeTxEvidence memory evidence;
        evidence.signedSafeTx.safeTx.to = TRANSMITTER;
        evidence.signedSafeTx.safeTx.operation = 1;
        evidence.signedSafeTx.safeTx.data = abi.encodeCall(ISignedTransmitter.bootstrap, (payload, new bytes[](0)));
        evidence.signedSafeTx.signatures =
            SafeSigs.blob(_quorum(), SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, SAFE, SOURCE_CHAIN));
        vm.expectRevert(abi.encodeWithSelector(SignedDispatchCalls.NotSourceCall.selector, TRANSMITTER));
        _initialize(r, abi.encode(SignedBootstrap(evidence, _records())));
    }

    function test_aNonzeroAuthorityCounterRefuses() public {
        address r = _plainReceiver();
        BootstrapLeaf memory leaf = _bootstrapLeaf(r, _calls("x"));
        bytes memory payload = abi.encode(DispatchLeaves.hash(leaf), uint256(1), leaf, new bytes32[](0));
        SafeTxEvidence memory evidence =
            _signed(abi.encodeCall(ISignedTransmitter.bootstrap, (payload, new bytes[](0))), _quorum());
        vm.expectRevert(abi.encodeWithSelector(SignedDispatchCalls.AuthorityCounterMismatch.selector, 1));
        _initialize(r, abi.encode(SignedBootstrap(evidence, _records())));
    }

    function test_theSameBootstrapRepeatsInItsWindowAndNothingElseDoes() public {
        address r = _plainReceiver();
        BootstrapLeaf memory leaf = _bootstrapLeaf(r, _calls("x"));
        bytes memory body = _bootstrapBody(leaf, _quorum());
        _initialize(r, body);
        SignedReceiver(payable(r)).requireBootstrapRepeat(body);

        bytes memory other = _bootstrapBody(_bootstrapLeaf(r, _calls("y")), _quorum());
        vm.expectPartialRevert(SignedReceiver.NotTheBootstrap.selector);
        SignedReceiver(payable(r)).requireBootstrapRepeat(other);

        vm.warp(leaf.deadline + 1);
        vm.expectPartialRevert(SignedDispatchCalls.WindowClosed.selector);
        SignedReceiver(payable(r)).requireBootstrapRepeat(body);
    }

    function test_aSecondInitializationRefuses() public {
        bytes memory body = _bootstrapBody(_bootstrapLeaf(receiver, _calls("x")), _quorum());
        vm.expectRevert(SignedReceiver.AlreadySigned.selector);
        _initialize(receiver, body);
    }

    /* ================================ standalone ================================ */

    function _message(bytes memory recipient, bytes memory calls) internal returns (SafeTxEvidence memory) {
        return _signed(abi.encodeCall(IERC7786GatewaySource.sendMessage, (recipient, calls, new bytes[](0))), _quorum());
    }

    function _deliver(bytes memory wire) internal {
        vm.prank(address(mailbox));
        HyperlaneReceiver(payable(receiver)).handle(HOME_DOMAIN, bytes32(uint256(uint160(TRANSMITTER))), wire);
    }

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

    function test_aStandaloneMessageForAnotherRecipientRefuses() public {
        bytes memory elsewhere = Erc7930.encodeEvm(block.chainid, address(0xD00D));
        SafeTxEvidence memory evidence = _message(elsewhere, _calls("m"));
        vm.expectRevert(abi.encodeWithSelector(SignedDispatchCalls.WrongDestination.selector, elsewhere));
        ISignedReceiver(receiver).submitMessage(evidence);
    }

    function test_alteredCalldataOrAnotherTargetRefuses() public {
        SafeTxEvidence memory evidence = _message(_here(receiver), _calls("m"));
        evidence.signedSafeTx.safeTx.data =
            abi.encodeCall(IERC7786GatewaySource.sendMessage, (_here(receiver), _calls("n"), new bytes[](0)));
        vm.expectPartialRevert(SafeAuthority.NotAnOwner.selector);
        ISignedReceiver(receiver).submitMessage(evidence);

        evidence = _message(_here(receiver), _calls("m"));
        evidence.signedSafeTx.safeTx.to = address(0x8888);
        vm.expectRevert(abi.encodeWithSelector(SignedDispatchCalls.NotSourceCall.selector, TRANSMITTER));
        ISignedReceiver(receiver).submitMessage(evidence);
    }

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

    function test_aPlainPayloadFromTheProviderRefuses() public {
        vm.expectRevert(abi.encodeWithSelector(SignedReceiver.UnknownWire.selector, 32));
        _deliver(_calls("plain"));
    }

    /* =================================== leaves ================================= */

    function _leaf(uint256 nonce, bytes memory calls) internal view returns (ExecutionLeaf memory leaf) {
        leaf.destination = _here(receiver);
        leaf.nonce = nonce;
        leaf.validAfter = block.timestamp;
        leaf.deadline = block.timestamp + 1 days;
        leaf.calls = calls;
        leaf.attributes = new bytes[](0);
    }

    function _register(ExecutionLeaf[] memory leaves)
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
        evidence = _signed(abi.encodeCall(ISignedTransmitter.registerRoot, (MerkleBuilder.root(hashes))), _quorum());
    }

    function _one(ExecutionLeaf memory a) internal pure returns (ExecutionLeaf[] memory l) {
        l = new ExecutionLeaf[](1);
        l[0] = a;
    }

    function _two(ExecutionLeaf memory a, ExecutionLeaf memory b) internal pure returns (ExecutionLeaf[] memory l) {
        l = new ExecutionLeaf[](2);
        (l[0], l[1]) = (a, b);
    }

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

    function test_aConflictingLeafAtAConsumedNonceRefuses() public {
        (SafeTxEvidence memory evidence, bytes32[][] memory p) =
            _register(_two(_leaf(0, _calls("a")), _leaf(0, _calls("b"))));
        ISignedReceiver(receiver).submitLeaf(evidence, _leaf(0, _calls("a")), p[0]);
        vm.expectRevert(abi.encodeWithSelector(SignedReceiver.ConflictingLeaf.selector, 0));
        ISignedReceiver(receiver).submitLeaf(evidence, _leaf(0, _calls("b")), p[1]);
    }

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

    function test_anEmptyReplacementLeafAdvancesTheNonce() public {
        (SafeTxEvidence memory evidence, bytes32[][] memory p) = _register(_one(_leaf(0, abi.encode(new Call[](0)))));
        ISignedReceiver(receiver).submitLeaf(evidence, _leaf(0, abi.encode(new Call[](0))), p[0]);
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 1);
        assertEq(sink.hits(), 1);
    }

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

    function test_aStandaloneAuthorizationIsNotARootRegistration() public {
        ExecutionLeaf memory l0 = _leaf(0, _calls("0"));
        SafeTxEvidence memory evidence = _message(_here(receiver), _calls("m"));
        vm.expectRevert(abi.encodeWithSelector(Slices.WrongSelector.selector, ISignedTransmitter.registerRoot.selector));
        ISignedReceiver(receiver).submitLeaf(evidence, l0, new bytes32[](0));
    }

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

    function test_aPlainReceiverRefusesSignedSubmission() public {
        address r = _plainReceiver();
        SafeTxEvidence memory evidence = _message(_here(r), _calls("m"));
        vm.expectRevert(SignedReceiver.NotSigned.selector);
        ISignedReceiver(r).submitMessage(evidence);
    }
    bytes private reentryCall;
    bool private reentryAttempted;

    function attemptReentry() external {
        require(msg.sender == receiver);
        reentryAttempted = true;
        (bool ok, bytes memory reason) = receiver.call(reentryCall);
        assertFalse(ok, "nested dispatch succeeded");
        assertEq(reason, abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
    }

    function test_reentrancyAcrossAllSignedEntryRoutes() public {
        for (uint256 outer; outer < 4; ++outer) {
            for (uint256 inner; inner < 3; ++inner) {
                _reentryScenario(outer, inner);
            }
        }
    }

    function _reentryScenario(uint256 outer, uint256 inner) private {
        uint256 nonce = SignedReceiver(payable(receiver)).nextNonce();
        SafeTxEvidence memory nestedMessageEvidence = _message(_here(receiver), _calls("nested"));
        ExecutionLeaf memory nestedLeaf = _leaf(nonce + 1, _calls("nested leaf"));
        (SafeTxEvidence memory nestedRegistrationEvidence, bytes32[][] memory nestedProof) = _register(_one(nestedLeaf));
        if (inner == 0) {
            reentryCall = abi.encodeCall(ISignedReceiver.submitMessage, (nestedMessageEvidence));
        } else if (inner == 1) {
            reentryCall =
                abi.encodeCall(ISignedReceiver.submitLeaf, (nestedRegistrationEvidence, nestedLeaf, nestedProof[0]));
        } else {
            reentryCall = abi.encodeWithSignature("finalize((address,uint256,bytes)[])", new Call[](0));
        }
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(this), 0, abi.encodeCall(this.attemptReentry, ()));
        reentryAttempted = false;
        if (outer < 2) {
            SafeTxEvidence memory evidence = _message(_here(receiver), abi.encode(calls));
            if (outer == 0) ISignedReceiver(receiver).submitMessage(evidence);
            else _deliver(abi.encode(WIRE_STANDALONE, evidence));
        } else {
            ExecutionLeaf memory leaf = _leaf(nonce, abi.encode(calls));
            (SafeTxEvidence memory evidence, bytes32[][] memory proof) = _register(_one(leaf));
            if (outer == 2) ISignedReceiver(receiver).submitLeaf(evidence, leaf, proof[0]);
            else _deliver(abi.encode(WIRE_MERKLE, evidence, leaf, proof[0]));
        }
        assertTrue(reentryAttempted);
        uint256 before = sink.hits();
        // A refused nested message remains usable after the outer lock is released.
        ISignedReceiver(receiver).submitMessage(nestedMessageEvidence);
        assertEq(sink.hits(), before + 1);
    }

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
