// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {HyperlaneReceiver} from "src/protocols/hyperlane/HyperlaneReceiver.sol";
import {IReceiverInit, ReceiverBase, ICommitFinalize, ICancel} from "src/messaging/inbound/ReceiverBase.sol";
import {SignedReceiver} from "src/messaging/signed/SignedReceiver.sol";
import {SignedCalls} from "src/messaging/signed/SignedCalls.sol";
import {SafeAuthority} from "src/messaging/signed/SafeAuthority.sol";
import {DispatchLeaves} from "src/messaging/signed/DispatchLeaves.sol";
import {AuthorityGraph} from "src/messaging/signed/AuthorityGraph.sol";
import {ISignedOwnerCalls} from "src/messaging/signed/ISignedOwnerCalls.sol";
import {IERC7786GatewaySource} from "src/messaging/IErc7786.sol";
import {Slices} from "src/messaging/signed/Slices.sol";
import {
    SafeRecord,
    ExecutionLeaf,
    BootstrapLeaf,
    SignedDelivery,
    SignedBootstrap,
    ISignedReceiver,
    WIRE_STANDALONE,
    WIRE_MERKLE
} from "src/messaging/signed/ISignedDispatch.sol";
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

    function _records() internal pure returns (SafeRecord[] memory) {
        return Records.list(Records.record(SAFE, 2, Records.eoaOwners(Records.pks(1, 2, 3))));
    }

    function _graph() internal pure returns (bytes32) {
        return AuthorityGraph.hash(_records());
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

    function _signed(bytes memory data, Sig[] memory sigs) internal returns (SignedDelivery memory d) {
        d.safeTx.to = TRANSMITTER;
        d.safeTx.data = data;
        d.safeTx.nonce = ++nonceSeq;
        d.signatures = SafeSigs.blob(sigs, SafeHashes.transactionHash(d.safeTx, SAFE, SOURCE_CHAIN));
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
        SignedDelivery memory d = _signed(abi.encodeCall(ISignedOwnerCalls.bootstrap, (payload, new bytes[](0))), sigs);
        return abi.encode(SignedBootstrap(d, _records()));
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
        vm.expectRevert(abi.encodeWithSelector(SignedReceiver.GraphMismatch.selector, keccak256("g"), _graph()));
        SignedReceiver(payable(r)).initializeSigned(SOURCE_CHAIN, SAFE, keccak256("g"), body);

        vm.expectRevert(abi.encodeWithSelector(SignedReceiver.RootIsNotOwner.selector, address(0x1), SAFE));
        SignedReceiver(payable(r)).initializeSigned(SOURCE_CHAIN, address(0x1), _graph(), body);
    }

    function test_aBootstrapForAnotherReceiverRefuses() public {
        address r = _plainReceiver();
        bytes memory body = _bootstrapBody(_bootstrapLeaf(receiver, _calls("x")), _quorum());
        vm.expectRevert(abi.encodeWithSelector(SignedCalls.WrongDestination.selector, _here(receiver)));
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
        vm.expectRevert(abi.encodeWithSelector(SignedCalls.WindowClosed.selector, leaf.validAfter, leaf.deadline));
        _initialize(r, _bootstrapBody(leaf, _quorum()));

        leaf = _bootstrapLeaf(r, _calls("x"));
        leaf.validAfter = block.timestamp - 10;
        leaf.deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(SignedCalls.WindowClosed.selector, leaf.validAfter, leaf.deadline));
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
        SignedDelivery memory d;
        d.safeTx.to = TRANSMITTER;
        d.safeTx.operation = 1;
        d.safeTx.data = abi.encodeCall(ISignedOwnerCalls.bootstrap, (payload, new bytes[](0)));
        d.signatures = SafeSigs.blob(_quorum(), SafeHashes.transactionHash(d.safeTx, SAFE, SOURCE_CHAIN));
        vm.expectRevert(abi.encodeWithSelector(SignedCalls.NotSourceCall.selector, TRANSMITTER));
        _initialize(r, abi.encode(SignedBootstrap(d, _records())));
    }

    function test_aNonzeroAuthorityCounterRefuses() public {
        address r = _plainReceiver();
        BootstrapLeaf memory leaf = _bootstrapLeaf(r, _calls("x"));
        bytes memory payload = abi.encode(DispatchLeaves.hash(leaf), uint256(1), leaf, new bytes32[](0));
        SignedDelivery memory d =
            _signed(abi.encodeCall(ISignedOwnerCalls.bootstrap, (payload, new bytes[](0))), _quorum());
        vm.expectRevert(abi.encodeWithSelector(SignedCalls.AuthorityCounterMismatch.selector, 1));
        _initialize(r, abi.encode(SignedBootstrap(d, _records())));
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
        vm.expectPartialRevert(SignedCalls.WindowClosed.selector);
        SignedReceiver(payable(r)).requireBootstrapRepeat(body);
    }

    function test_aSecondInitializationRefuses() public {
        bytes memory body = _bootstrapBody(_bootstrapLeaf(receiver, _calls("x")), _quorum());
        vm.expectRevert(SignedReceiver.AlreadySigned.selector);
        _initialize(receiver, body);
    }

    /* ================================ standalone ================================ */

    function _message(bytes memory recipient, bytes memory calls) internal returns (SignedDelivery memory) {
        return _signed(abi.encodeCall(IERC7786GatewaySource.sendMessage, (recipient, calls, new bytes[](0))), _quorum());
    }

    function _deliver(bytes memory wire) internal {
        vm.prank(address(mailbox));
        HyperlaneReceiver(payable(receiver)).handle(HOME_DOMAIN, bytes32(uint256(uint160(TRANSMITTER))), wire);
    }

    function test_aStandaloneMessageRunsOnceAcrossBothRoutes() public {
        SignedDelivery memory d = _message(_here(receiver), _calls("m"));
        ISignedReceiver(receiver).submitMessage{value: 1}(d);
        assertEq(sink.hits(), 2);
        assertEq(receiver.balance, 1);

        vm.recordLogs();
        _deliver(abi.encode(WIRE_STANDALONE, d));
        assertEq(sink.hits(), 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], ISignedReceiver.DuplicateMessage.selector);
    }

    function test_aStandaloneMessageForAnotherRecipientRefuses() public {
        bytes memory elsewhere = Erc7930.encodeEvm(block.chainid, address(0xD00D));
        SignedDelivery memory d = _message(elsewhere, _calls("m"));
        vm.expectRevert(abi.encodeWithSelector(SignedCalls.WrongDestination.selector, elsewhere));
        ISignedReceiver(receiver).submitMessage(d);
    }

    function test_alteredCalldataOrAnotherTargetRefuses() public {
        SignedDelivery memory d = _message(_here(receiver), _calls("m"));
        d.safeTx.data =
            abi.encodeCall(IERC7786GatewaySource.sendMessage, (_here(receiver), _calls("n"), new bytes[](0)));
        vm.expectPartialRevert(SafeAuthority.NotAnOwner.selector);
        ISignedReceiver(receiver).submitMessage(d);

        d = _message(_here(receiver), _calls("m"));
        d.safeTx.to = address(0x8888);
        vm.expectRevert(abi.encodeWithSelector(SignedCalls.NotSourceCall.selector, TRANSMITTER));
        ISignedReceiver(receiver).submitMessage(d);
    }

    function test_aProviderWithTheWrongSenderRefusesAndDirectSubmissionStillWorks() public {
        SignedDelivery memory d = _message(_here(receiver), _calls("m"));
        vm.prank(address(mailbox));
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        HyperlaneReceiver(payable(receiver))
            .handle(HOME_DOMAIN, bytes32(uint256(0xBAD)), abi.encode(WIRE_STANDALONE, d));
        assertEq(sink.hits(), 1);
        ISignedReceiver(receiver).submitMessage(d);
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
        returns (SignedDelivery memory d, bytes32[][] memory proofs)
    {
        bytes32[] memory hashes = new bytes32[](leaves.length);
        for (uint256 i; i < leaves.length; ++i) {
            hashes[i] = DispatchLeaves.hash(leaves[i]);
        }
        proofs = new bytes32[][](leaves.length);
        for (uint256 i; i < leaves.length; ++i) {
            proofs[i] = MerkleBuilder.proof(hashes, i);
        }
        d = _signed(abi.encodeCall(ISignedOwnerCalls.registerRoot, (MerkleBuilder.root(hashes))), _quorum());
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
        (SignedDelivery memory d, bytes32[][] memory proofs) = _register(_one(leaf));
        d.safeTx.value = 1;
        d.signatures = SafeSigs.blob(_quorum(), SafeHashes.transactionHash(d.safeTx, SAFE, SOURCE_CHAIN));

        vm.expectRevert(abi.encodeWithSelector(SignedCalls.NonzeroRegistrationValue.selector, 1));
        ISignedReceiver(receiver).submitLeaf(d, leaf, proofs[0]);
        vm.expectRevert(abi.encodeWithSelector(SignedCalls.NonzeroRegistrationValue.selector, 1));
        _deliver(abi.encode(WIRE_MERKLE, d, leaf, proofs[0]));
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 0);
        assertEq(sink.hits(), 1);
    }

    function test_leavesRunInLocalNonceOrderAcrossRoutes() public {
        ExecutionLeaf memory l0 = _leaf(0, _calls("0"));
        ExecutionLeaf memory l1 = _leaf(1, _calls("1"));
        (SignedDelivery memory d, bytes32[][] memory p) = _register(_two(l0, l1));

        vm.expectRevert(abi.encodeWithSelector(SignedReceiver.NonceNotNext.selector, 1, 0));
        ISignedReceiver(receiver).submitLeaf(d, l1, p[1]);

        _deliver(abi.encode(WIRE_MERKLE, d, l0, p[0]));
        ISignedReceiver(receiver).submitLeaf(d, l1, p[1]);
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 2);
        assertEq(sink.hits(), 3);
    }

    function test_anExecutedLeafRepeatsSilentlyEvenPastItsDeadlineAndUnderNewAttributes() public {
        ExecutionLeaf memory l0 = _leaf(0, _calls("0"));
        (SignedDelivery memory d, bytes32[][] memory p) = _register(_one(l0));
        ISignedReceiver(receiver).submitLeaf(d, l0, p[0]);

        ExecutionLeaf memory reattributed = _leaf(0, _calls("0"));
        reattributed.attributes = new bytes[](1);
        reattributed.attributes[0] = hex"01";
        (SignedDelivery memory d2, bytes32[][] memory p2) = _register(_one(reattributed));

        vm.warp(l0.deadline + 1);
        vm.recordLogs();
        ISignedReceiver(receiver).submitLeaf{value: 5}(d2, reattributed, p2[0]);
        _deliver(abi.encode(WIRE_MERKLE, d, l0, p[0]));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(sink.hits(), 2);
        assertEq(receiver.balance, 5);
    }

    function test_aConflictingLeafAtAConsumedNonceRefuses() public {
        (SignedDelivery memory d, bytes32[][] memory p) = _register(_two(_leaf(0, _calls("a")), _leaf(0, _calls("b"))));
        ISignedReceiver(receiver).submitLeaf(d, _leaf(0, _calls("a")), p[0]);
        vm.expectRevert(abi.encodeWithSelector(SignedReceiver.ConflictingLeaf.selector, 0));
        ISignedReceiver(receiver).submitLeaf(d, _leaf(0, _calls("b")), p[1]);
    }

    function test_windowEndpointsAreInclusive() public {
        ExecutionLeaf memory l0 = _leaf(0, _calls("0"));
        l0.validAfter = block.timestamp + 10;
        l0.deadline = block.timestamp + 20;
        (SignedDelivery memory d, bytes32[][] memory p) = _register(_one(l0));

        vm.warp(l0.validAfter - 1);
        vm.expectRevert(abi.encodeWithSelector(SignedCalls.WindowClosed.selector, l0.validAfter, l0.deadline));
        ISignedReceiver(receiver).submitLeaf(d, l0, p[0]);

        vm.warp(l0.deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(SignedCalls.WindowClosed.selector, l0.validAfter, l0.deadline));
        ISignedReceiver(receiver).submitLeaf(d, l0, p[0]);
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 0);

        vm.warp(l0.deadline);
        ISignedReceiver(receiver).submitLeaf(d, l0, p[0]);
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 1);
    }

    function test_anEmptyReplacementLeafAdvancesTheNonce() public {
        (SignedDelivery memory d, bytes32[][] memory p) = _register(_one(_leaf(0, abi.encode(new Call[](0)))));
        ISignedReceiver(receiver).submitLeaf(d, _leaf(0, abi.encode(new Call[](0))), p[0]);
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 1);
        assertEq(sink.hits(), 1);
    }

    function test_aFailingLeafRollsBackAndCanBeRetried() public {
        Call[] memory c = new Call[](1);
        c[0] = Call(address(sink), 0, abi.encodeCall(Sink.boom, ()));
        ExecutionLeaf memory l0 = _leaf(0, abi.encode(c));
        (SignedDelivery memory d, bytes32[][] memory p) = _register(_one(l0));
        vm.expectPartialRevert(bytes4(keccak256("CallFailed(uint256,bytes)")));
        ISignedReceiver(receiver).submitLeaf(d, l0, p[0]);
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 0);
        assertEq(SignedReceiver(payable(receiver)).executionAt(0), bytes32(0));
    }

    function test_aStandaloneAuthorizationIsNotARootRegistration() public {
        ExecutionLeaf memory l0 = _leaf(0, _calls("0"));
        SignedDelivery memory d = _message(_here(receiver), _calls("m"));
        vm.expectRevert(abi.encodeWithSelector(Slices.WrongSelector.selector, ISignedOwnerCalls.registerRoot.selector));
        ISignedReceiver(receiver).submitLeaf(d, l0, new bytes32[](0));
    }

    function test_anAlteredLeafOrAProofUnderAnotherRootRefuses() public {
        ExecutionLeaf memory l0 = _leaf(0, _calls("0"));
        (SignedDelivery memory d, bytes32[][] memory p) = _register(_one(l0));
        ExecutionLeaf memory altered = _leaf(0, _calls("1"));
        vm.expectRevert(DispatchLeaves.InvalidProof.selector);
        ISignedReceiver(receiver).submitLeaf(d, altered, p[0]);
        // Repeat after execution still authenticates first.
        ISignedReceiver(receiver).submitLeaf(d, l0, p[0]);
        vm.expectRevert(DispatchLeaves.InvalidProof.selector);
        ISignedReceiver(receiver).submitLeaf(d, altered, p[0]);
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
        (SignedDelivery memory d, bytes32[][] memory p) = _register(_two(l0, l1));
        ISignedReceiver(receiver).submitLeaf(d, l0, p[0]);
        assertTrue(ReceiverBase(payable(receiver)).isCommitted(commitment));
        ISignedReceiver(receiver).submitLeaf(d, l1, p[1]);

        ICommitFinalize(receiver).finalize(later);
        assertEq(SignedReceiver(payable(receiver)).nextNonce(), 2);
        assertEq(sink.last(), "later");
    }

    function test_aSignedRevokeStopsTheProviderAndLeavesDirectSubmission() public {
        Call[] memory revoke = new Call[](1);
        revoke[0] = Call(receiver, 0, abi.encodeCall(ReceiverBase.revokeGateway, (address(mailbox))));
        ISignedReceiver(receiver).submitMessage(_message(_here(receiver), abi.encode(revoke)));

        SignedDelivery memory d = _message(_here(receiver), _calls("m"));
        vm.expectRevert();
        _deliver(abi.encode(WIRE_STANDALONE, d));
        ISignedReceiver(receiver).submitMessage(d);
        assertEq(sink.hits(), 2);
    }

    function test_aPlainReceiverRefusesSignedSubmission() public {
        address r = _plainReceiver();
        SignedDelivery memory d = _message(_here(r), _calls("m"));
        vm.expectRevert(SignedReceiver.NotSigned.selector);
        ISignedReceiver(r).submitMessage(d);
    }
}
