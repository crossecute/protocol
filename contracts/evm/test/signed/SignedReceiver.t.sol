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
        return SafeAuthorityGraph.hash(_records());
    }

    /// @notice Deploy a provider receiver with plain initialization but no setup calls.
    /// @dev Tests can exercise the second signed-initialization step and ensure it is properly
    ///      restricted.
    function _plainReceiver() internal returns (address r) {
        r = deployConduit(
            address(new HyperlaneReceiver(address(mailbox))),
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

    /// @notice Build a setup leaf for the selected receiver inside a one-day window.
    /// @dev Initialization tests start from an executable destination and window before
    ///      mutating a specific condition.
    function _bootstrapLeaf(address r, bytes memory setup) internal view returns (BootstrapLeaf memory) {
        return BootstrapLeaf(_here(r), block.timestamp, block.timestamp + 1 days, setup);
    }

    /// @notice Sign a single-leaf bootstrap and package its authority records.
    /// @dev The receiver needs the complete authorization body even when a one-leaf tree
    ///      requires no siblings.
    function _bootstrapBody(BootstrapLeaf memory leaf, Sig[] memory sigs) internal returns (bytes memory) {
        bytes32 leafHash = DispatchLeaves.hash(leaf);
        bytes memory payload = abi.encode(leafHash, uint256(0), leaf, new bytes32[](0));
        SafeTxEvidence memory evidence =
            _signed(abi.encodeCall(ISignedTransmitter.bootstrap, (payload, new bytes[](0))), sigs);
        return abi.encode(SignedBootstrap(evidence, _records()));
    }

    /// @notice Call signed initialization as the configured parent transceiver.
    /// @dev Ordinary setup helpers must satisfy the caller restriction so tests isolate other
    ///      validation rules.
    function _initialize(address r, bytes memory body) internal {
        SignedReceiver(payable(r)).initializeSigned(SOURCE_CHAIN, SAFE, _graph(), body);
    }

    /// @notice Deploy and initialize a signed receiver with an observable setup call.
    /// @dev Each test starts with a stored source authority and a known setup effect for replay
    ///      and rollback assertions.
    function setUp() public {
        vm.warp(1_000_000);
        receiver = _plainReceiver();
        _initialize(receiver, _bootstrapBody(_bootstrapLeaf(receiver, _calls("setup")), _quorum()));
    }

    /* ================================ bootstrap ================================= */

    /// @notice Inspect the authority, nonce, setup effects and protected-call access after
    ///         initialization.
    /// @dev Successful setup must establish signed verification state without authorizing the
    ///      transmitter address itself.
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

    /// @notice Attempt signed initialization from an unrelated caller.
    /// @dev Only the transceiver that created the receiver may establish its authority
    ///      snapshot.
    function test_onlyTheParentTransceiverInitializes() public {
        address r = _plainReceiver();
        bytes memory body = _bootstrapBody(_bootstrapLeaf(r, _calls("x")), _quorum());
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(SignedReceiver.NotParentTransceiver.selector, address(0xBAD)));
        SignedReceiver(payable(r)).initializeSigned(SOURCE_CHAIN, SAFE, _graph(), body);
    }

    /// @notice Initialize with a mismatched graph commitment or source owner.
    /// @dev Neither the authority snapshot nor its root Safe may be substituted after address
    ///      derivation.
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

    /// @notice Submit bootstrap evidence naming a different destination receiver.
    /// @dev A valid setup signature must not authorize initialization at an unintended address.
    function test_aBootstrapForAnotherReceiverRefuses() public {
        address r = _plainReceiver();
        bytes memory body = _bootstrapBody(_bootstrapLeaf(receiver, _calls("x")), _quorum());
        vm.expectRevert(abi.encodeWithSelector(SignedDispatchCalls.WrongDestination.selector, _here(receiver)));
        _initialize(r, body);
    }

    /// @notice Submit a bootstrap with too few valid owner signatures.
    /// @dev Receiver creation must require the stored source Safe's full quorum.
    function test_aBootstrapWithoutQuorumRefuses() public {
        address r = _plainReceiver();
        bytes memory body = _bootstrapBody(_bootstrapLeaf(r, _calls("x")), SafeSigs.one(SafeSigs.eoa(1)));
        vm.expectPartialRevert(bytes4(keccak256("SignaturesTooShort(address)")));
        _initialize(r, body);
    }

    /// @notice Try bootstrap before its start, after its deadline and with reversed endpoints.
    /// @dev Initialization must honor the entire signed timing constraint.
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

    /// @notice Make the setup batch fail during signed initialization.
    /// @dev A receiver must not remain partially initialized when authorized setup cannot
    ///      complete.
    function test_aRevertingSetupRevertsInitialization() public {
        address r = _plainReceiver();
        Call[] memory c = new Call[](1);
        c[0] = Call(address(sink), 0, abi.encodeCall(Sink.boom, ()));
        vm.expectPartialRevert(bytes4(keccak256("CallFailed(uint256,bytes)")));
        _initialize(r, _bootstrapBody(_bootstrapLeaf(r, abi.encode(c)), _quorum()));
    }

    /// @notice Sign bootstrap as a DELEGATECALL instead of CALL.
    /// @dev Destination acceptance must match the supported source-transmitter operation.
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

    /// @notice Carry a nonzero authority counter in the bootstrap payload.
    /// @dev This implementation fixes creation authority and must not imply support for later
    ///      counter updates.
    function test_aNonzeroAuthorityCounterRefuses() public {
        address r = _plainReceiver();
        BootstrapLeaf memory leaf = _bootstrapLeaf(r, _calls("x"));
        bytes memory payload = abi.encode(DispatchLeaves.hash(leaf), uint256(1), leaf, new bytes32[](0));
        SafeTxEvidence memory evidence =
            _signed(abi.encodeCall(ISignedTransmitter.bootstrap, (payload, new bytes[](0))), _quorum());
        vm.expectRevert(abi.encodeWithSelector(SignedDispatchCalls.AuthorityCounterMismatch.selector, 1));
        _initialize(r, abi.encode(SignedBootstrap(evidence, _records())));
    }

    /// @notice Retry the original bootstrap, then vary its leaf or time window.
    /// @dev Transport retries should acknowledge setup without rerunning it or accepting a new
    ///      initialization authorization.
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

    /// @notice Call signed initialization again on an initialized receiver.
    /// @dev Stored authority must not be overwritten through the creation entry point.
    function test_aSecondInitializationRefuses() public {
        bytes memory body = _bootstrapBody(_bootstrapLeaf(receiver, _calls("x")), _quorum());
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
        vm.expectPartialRevert(SafeAuthority.NotAnOwner.selector);
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

    /// @notice Attempt the selected nested receiver call and assert the shared lock rejects it.
    /// @dev An executing payload can call back into the receiver, so reentrancy protection must
    ///      be tested from inside execution.
    function attemptReentry() external {
        require(msg.sender == receiver);
        reentryAttempted = true;
        (bool ok, bytes memory reason) = receiver.call(reentryCall);
        assertFalse(ok, "nested dispatch succeeded");
        assertEq(reason, abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
    }

    /// @notice Exercise each direct and provider route against nested message, leaf and
    ///         finalization entry.
    /// @dev A lock that protects only one route would leave cross-route reentrancy available.
    function test_reentrancyAcrossAllSignedEntryRoutes() public {
        for (uint256 outer; outer < 4; ++outer) {
            for (uint256 inner; inner < 3; ++inner) {
                _reentryScenario(outer, inner);
            }
        }
    }

    /// @notice Execute one outer/inner route combination and retry its refused nested message
    ///         afterward.
    /// @dev Reentrancy rejection must preserve both the outer operation and the future
    ///      usability of unexecuted evidence.
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
