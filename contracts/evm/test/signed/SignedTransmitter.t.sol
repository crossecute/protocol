// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ICrossecuteGuard, SafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {IERC7786GatewaySource} from "src/messaging/IErc7786.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {Call} from "src/messaging/Call.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {SignedTransmitter} from "src/messaging/outbound/SignedTransmitter.sol";
import {SignedTransmitterLib} from "src/messaging/outbound/SignedTransmitterLib.sol";
import {SignedDispatchCalls} from "src/messaging/signed/SignedDispatchCalls.sol";
import {SafeSignaturesUtils} from "src/messaging/signed/SafeSignaturesUtils.sol";
import {DispatchLeaves} from "src/messaging/signed/DispatchLeaves.sol";
import {ISignedTransmitter} from "src/messaging/outbound/ISignedTransmitter.sol";
import {SafeAuthorityRecord} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {
    ExecutionLeaf,
    BootstrapLeaf,
    SafeTxEvidence,
    SignedBootstrap,
    NestedSafeApproval,
    WIRE_STANDALONE,
    WIRE_MERKLE
} from "src/messaging/signed/types/SignedDispatchTypes.sol";

import {unseeded} from "test/RegistrySeed.sol";
import {ext} from "test/Harness.sol";
import {HyperlaneFixture} from "test/protocols/hyperlane/HyperlaneFixture.sol";
import {MerkleBuilder, SafeSigs, Sig} from "test/signed/SignedFixtures.sol";
import {StubSafe, StubGuard} from "test/signed/StubSafe.sol";

/// @notice Rejects every refund, to show a failed refund reverts the relay.
contract RefuseEth {
    /// @notice Forward a leaf relay from a contract that cannot receive refunds.
    /// @dev The transmitter test needs refund rejection to originate from the actual relayer
    ///      address.
    function relay(SignedTransmitter st, SafeTxEvidence memory evidence, ExecutionLeaf memory l, bytes32[] memory p)
        external
        payable
    {
        st.relayLeaf{value: msg.value}(evidence, l, p);
    }
}

/// @notice Tries to reenter the same relay when its provider sends a refund directly.
contract ReenterRefund {
    address internal transmitter;
    bytes internal relayData;
    bool public blocked;

    /// @notice Relay while retaining the exact calldata for a refund callback attempt.
    function relay(address target, bytes memory data) external payable {
        transmitter = target;
        relayData = data;
        (bool ok, bytes memory reason) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
    }

    /// @notice Record that the transmitter's relay lock rejects provider-refund reentry.
    receive() external payable {
        (bool ok, bytes memory reason) = transmitter.call(relayData);
        blocked = !ok && bytes4(reason) == SignedTransmitter.RelayReentered.selector;
    }
}

/// @dev The transmitter in signed mode (#108) behind a real Hyperlane transceiver, with a stub
///      Safe whose stub guard stages what the test signs. The Safe's `exec` stands in for
///      `execTransaction` after the guard's pre-hook.
contract SignedTransmitterTest is HyperlaneFixture {
    bytes32 constant SALT = keccak256("user salt");

    TransceiverBase t;
    bytes32 remote;
    StubSafe safe;
    StubGuard guard;
    SignedTransmitter st;
    uint256 safeNonce;

    /// @notice Deploy a routed Hyperlane transmitter for a guarded 2-of-3 stub Safe and fund
    ///         it.
    /// @dev Tests need real transport and fee behavior while controlling which transaction
    ///      evidence the guard stages.
    function setUp() public {
        vm.warp(1_000_000);
        TransceiverConfig memory c = _config();
        c.transmitterImplementation = _transmitterImplementation();
        t = TransceiverBase(payable(_deployTransceiver(c, 0)));
        ChainRegistry registry = new ChainRegistry(address(this), unseeded());
        bytes32 provider = registry.addMessageProvider("under-test");
        remote = registry.addChainKey(Erc7930.encodeEvmChain(REMOTE_CHAIN_ID), Provenance.Predetermined);
        _listAsDeployed(registry, provider, address(t), remote);
        vm.startPrank(t.owner());
        ext(address(t)).setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Unique);
        ext(address(t)).setRoute(remote, Erc7930.encodeEvmChain(REMOTE_CHAIN_ID));
        vm.stopPrank();
        _configureRemote(address(t), address(t));

        guard = new StubGuard();
        safe = _safe(_addrs(vm.addr(1), vm.addr(2), vm.addr(3)), 2);
        vm.prank(address(safe));
        st = SignedTransmitter(payable(t.createTransmitter(SALT)));
        vm.deal(address(st), 1 ether);
    }

    /// @notice Deploy a stub Safe with selected owners, threshold and the fixture guard.
    /// @dev Nested-owner tests can build children with distinct quorums using the same source
    ///      interfaces.
    function _safe(address[] memory owners, uint256 threshold) internal returns (StubSafe s) {
        s = new StubSafe();
        s.setOwners(owners, threshold);
        s.setGuard(address(guard));
    }

    /// @notice Build a three-address owner array in the supplied order.
    /// @dev The fixture's live owner order must match its creation authority snapshot.
    function _addrs(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    /// @notice Return two authorized fixture EOA signers.
    /// @dev Control cases need valid root authorization before individual tests alter a
    ///      signature or call.
    function _quorum() internal pure returns (Sig[] memory) {
        return SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(2));
    }

    /// @notice Build a source Safe transaction with the supplied target, data and a fresh
    ///         nonce.
    /// @dev Unique nonces keep independently signed fixture operations from accidentally
    ///      sharing transaction identity.
    function _safeTx(StubSafe s, address to, bytes memory data) internal returns (SafeTx memory safeTx) {
        safeTx.to = to;
        safeTx.data = data;
        safeTx.nonce = ++safeNonce;
        s;
    }

    /// @notice Sign a fixture transaction in the selected Safe's current-chain domain.
    /// @dev Transmitter tests need exact source-call evidence that can be staged, quoted and
    ///      carried to a receiver.
    function _delivery(StubSafe s, address to, bytes memory data, Sig[] memory sigs)
        internal
        returns (SafeTxEvidence memory evidence)
    {
        evidence.signedSafeTx.safeTx = _safeTx(s, to, data);
        evidence.signedSafeTx.signatures =
            SafeSigs.blob(sigs, SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, address(s), block.chainid));
    }

    /// @notice Stage the evidence in the guard, then forward its call through the stub Safe.
    /// @dev This models the real guard pre-hook followed by Safe execution so the transmitter
    ///      consumes the expected live record.
    function _exec(StubSafe s, SafeTxEvidence memory evidence) internal {
        guard.stage(address(s), evidence.signedSafeTx.safeTx, evidence.signedSafeTx.signatures);
        s.exec(evidence.signedSafeTx.safeTx.to, 0, evidence.signedSafeTx.safeTx.data);
    }

    /// @notice Encode the predicted remote receiver as a full destination address.
    /// @dev Routing tests must use the signed conduit destination rather than a bare or
    ///      unrelated contract address.
    function _receiverHere() internal view returns (bytes memory) {
        return Erc7930.encodeEvm(REMOTE_CHAIN_ID, _receiverAddress());
    }

    /// @notice Predict the remote receiver using the creation Safe, salt and authority graph.
    /// @dev The send and bootstrap fixture must agree with the transceiver's signed address
    ///      derivation.
    function _receiverAddress() internal view returns (address) {
        return address(bytes20(t.predictReceiver(remote, address(safe), SALT, st.authorityGraph())));
    }

    /// @notice Encode a zero-counter bootstrap authorizing one setup leaf.
    /// @dev A one-leaf root isolates bootstrap behavior without requiring sibling proof data.
    function _bootstrapCall(BootstrapLeaf memory leaf) internal pure returns (bytes memory) {
        bytes memory payload = abi.encode(DispatchLeaves.hash(leaf), uint256(0), leaf, new bytes32[](0));
        return abi.encodeCall(ISignedTransmitter.bootstrap, (payload, new bytes[](0)));
    }

    /// @notice Build a valid empty-setup bootstrap leaf for the predicted receiver.
    /// @dev Tests begin with a usable destination and timing window before mutating one
    ///      condition.
    function _leaf() internal view returns (BootstrapLeaf memory) {
        return BootstrapLeaf(_receiverHere(), block.timestamp, block.timestamp + 1 days, abi.encode(new Call[](0)));
    }

    /// @notice Read the last wire message recorded by the mock mailbox.
    /// @dev Assertions can inspect exactly what the transmitter paid to send.
    function _lastBody() internal view returns (bytes memory) {
        return mailbox.sent(mailbox.sentLength() - 1).body;
    }

    /// @notice Sign and execute the default bootstrap, returning its source evidence.
    /// @dev Later relay and send tests need a reachable destination established through the
    ///      real signed path.
    function _bootstrap() internal returns (SafeTxEvidence memory evidence) {
        evidence = _delivery(safe, address(st), _bootstrapCall(_leaf()), _quorum());
        _exec(safe, evidence);
    }

    /* ================================== bootstrap ================================ */

    /// @notice Decode a sent bootstrap and compare its authorization, authority records and
    ///         quote.
    /// @dev The destination must receive the same signed setup and snapshot that source
    ///      creation committed to.
    function test_aSignedBootstrapCarriesTheSignedCallAndTheCreationRecords() public {
        SafeTxEvidence memory evidence = _bootstrap();
        (address owner, bytes32 salt, bytes32 transmitter, bytes memory body) = this.decodeSigned(_lastBody());
        assertEq(owner, address(safe));
        assertEq(salt, SALT);
        assertEq(transmitter, bytes32(uint256(uint160(address(st)))));
        SignedBootstrap memory bootstrap = abi.decode(body, (SignedBootstrap));
        assertEq(bootstrap.evidence.signedSafeTx.safeTx.data, evidence.signedSafeTx.safeTx.data);
        assertEq(bootstrap.evidence.signedSafeTx.signatures, evidence.signedSafeTx.signatures);
        assertEq(keccak256(abi.encode(bootstrap.records)), st.authorityGraph());
        assertTrue(st.isBootstrapped(remote));
        assertEq(st.destinationReceiverOn(remote), abi.encodePacked(_receiverAddress()));
        assertEq(st.pendingBootstrap(remote), bytes32(0));
    }

    /// @notice Expose signed-bootstrap envelope decoding through an external helper.
    /// @dev Tests can inspect the provider body without duplicating the envelope's decoding
    ///      rules at every assertion.
    function decodeSigned(bytes calldata m) external pure returns (address, bytes32, bytes32, bytes memory) {
        return Envelope.decodeSignedBootstrap(m);
    }

    /// @notice Fail the initial bootstrap transport send and retry it from another caller.
    /// @dev Source Safe authorization should remain usable after a temporary provider failure
    ///      without requiring the owners to sign again.
    function test_aFailedSendStaysPendingAndAnyoneCanRetryIt() public {
        mailbox.setFee(2 ether);
        vm.recordLogs();
        _bootstrap();
        bytes memory body;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == SignedTransmitter.BootstrapPending.selector) {
                body = abi.decode(logs[i].data, (bytes));
            }
        }
        assertEq(st.pendingBootstrap(remote), keccak256(body));
        assertFalse(st.isBootstrapped(remote));

        bytes memory altered = abi.encodePacked(body, hex"00");
        vm.expectRevert(abi.encodeWithSelector(SignedTransmitter.NoPendingBootstrap.selector, remote));
        st.retryBootstrap(altered);

        hoax(address(0xF00));
        st.retryBootstrap{value: 2 ether}(body);
        assertTrue(st.isBootstrapped(remote));
        assertEq(st.pendingBootstrap(remote), bytes32(0));
    }

    /// @notice Create a new bootstrap authorization while an earlier send is pending.
    /// @dev Only the currently pending body should remain eligible for permissionless retry.
    function test_aNewSignedBootstrapReplacesAPendingOne() public {
        mailbox.setFee(2 ether);
        _bootstrap();
        bytes32 first = st.pendingBootstrap(remote);
        _bootstrap();
        assertTrue(st.pendingBootstrap(remote) != first);
    }

    /// @notice Call signed bootstrap without guard-staged evidence.
    /// @dev An owner-address call alone must not manufacture the signatures the receiver needs.
    function test_aBootstrapWithoutAStagedRecordReverts() public {
        bytes memory data = _bootstrapCall(_leaf());
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.NoLiveRecord.selector, address(safe)));
        safe.exec(address(st), 0, data);
    }

    /// @notice Try a substituted destination and an expired bootstrap.
    /// @dev Invalid setup authorization must fail on the source before transport fees are
    ///      spent.
    function test_aBootstrapForAnotherReceiverOrPastItsDeadlineReverts() public {
        BootstrapLeaf memory leaf = _leaf();
        leaf.destination = Erc7930.encodeEvm(REMOTE_CHAIN_ID, address(0xBAD));
        SafeTxEvidence memory evidence = _delivery(safe, address(st), _bootstrapCall(leaf), _quorum());
        guard.stage(address(safe), evidence.signedSafeTx.safeTx, evidence.signedSafeTx.signatures);
        vm.expectRevert(abi.encodeWithSelector(SignedTransmitterLib.WrongBootstrapTarget.selector, leaf.destination));
        safe.exec(address(st), 0, evidence.signedSafeTx.safeTx.data);

        leaf = _leaf();
        leaf.deadline = block.timestamp - 1;
        leaf.validAfter = block.timestamp - 2;
        evidence = _delivery(safe, address(st), _bootstrapCall(leaf), _quorum());
        guard.stage(address(safe), evidence.signedSafeTx.safeTx, evidence.signedSafeTx.signatures);
        vm.expectRevert(
            abi.encodeWithSelector(SignedDispatchCalls.WindowClosed.selector, leaf.validAfter, leaf.deadline)
        );
        safe.exec(address(st), 0, evidence.signedSafeTx.safeTx.data);
    }

    /// @notice Try bootstrap as another caller and attempt to transfer signed ownership.
    /// @dev The fixed creation Safe must remain the only owner-authorized source caller.
    function test_onlyTheOwnerBootstrapsAndOwnershipIsFixed() public {
        bytes memory data = _bootstrapCall(_leaf());
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        (bool ok,) = address(st).call(data);
        assertTrue(ok, "expectRevert");

        vm.prank(address(safe));
        vm.expectRevert(SignedTransmitter.OwnershipFixed.selector);
        st.transferOwnership(address(0x1));
    }

    /// @notice Try renouncing signed ownership, then bootstrap with the retained owner.
    /// @dev The ownership freeze must block permanent owner-only lockout and leave normal
    ///      operations usable.
    function test_signedOwnershipCannotBeRenounced() public {
        vm.prank(address(safe));
        vm.expectRevert(SignedTransmitter.OwnershipFixed.selector);
        st.renounceOwnership();
        assertEq(st.owner(), address(safe));
        // Refusal leaves the fixed owner able to bootstrap normally.
        _bootstrap();
        assertTrue(st.isBootstrapped(remote));
    }

    /// @notice Renounce ownership of a plain-mode transmitter.
    /// @dev Signed-mode restrictions must not change the inherited plain ownership behavior.
    function test_plainOwnershipCanStillBeRenounced() public {
        SignedTransmitter plain = SignedTransmitter(payable(t.createTransmitter(keccak256("plain"))));
        assertEq(plain.authorityGraph(), bytes32(0));
        plain.renounceOwnership();
        assertEq(plain.owner(), address(0));
    }

    /* ================================= standalone ================================ */

    /// @notice Sign and execute a standalone send to the selected recipient.
    /// @dev Tests can inspect both the staged source evidence and the wire message emitted by
    ///      the normal send path.
    function _send(bytes memory recipient, bytes memory payload) internal returns (SafeTxEvidence memory evidence) {
        evidence = _delivery(
            safe,
            address(st),
            abi.encodeCall(IERC7786GatewaySource.sendMessage, (recipient, payload, new bytes[](0))),
            _quorum()
        );
    }

    /// @notice Encode an empty call batch as a nonempty payload.
    /// @dev This provides valid signed message data without unrelated destination-side effects.
    function _payload() internal pure returns (bytes memory) {
        Call[] memory c = new Call[](1);
        c[0] = Call(address(0xCAFE), 0, hex"01");
        return abi.encode(c);
    }

    /// @notice Inspect the standalone wire payload and compare the paid fee with the signed
    ///         quote.
    /// @dev Rebuilding transport data must preserve exact signed calldata and include all
    ///      priced evidence bytes.
    function test_aStandaloneSendWrapsTheExactSignedCallAndPaysItsQuote() public {
        _bootstrap();
        mailbox.setFeePerByte(10);
        SafeTxEvidence memory evidence = _send(_receiverHere(), _payload());
        uint256 quote = st.quoteSignedMessage(evidence);
        uint256 before = address(st).balance;
        _exec(safe, evidence);

        assertEq(_lastBody(), abi.encode(WIRE_STANDALONE, evidence));
        assertEq(before - address(st).balance, quote);
        assertEq(quote, 10 * abi.encode(WIRE_STANDALONE, evidence).length);
    }

    /// @notice Call plain quote APIs on a signed transmitter.
    /// @dev A quote without signatures cannot price the signed wire payload accurately and must
    ///      direct callers to the signed API.
    function test_thePlainQuotesRefuseInSignedMode() public {
        bytes memory recipient = _receiverHere();
        vm.expectRevert(SignedTransmitter.SignedQuoteRequired.selector);
        st.quoteMessage(recipient, _payload(), new bytes[](0));
        vm.expectRevert(SignedTransmitter.SignedQuoteRequired.selector);
        st.quoteBootstrap(hex"00", new bytes[](0));
    }

    /// @notice Send a signed message before its destination is bootstrapped.
    /// @dev Signature evidence must not bypass the conduit's reachability requirement.
    function test_aStandaloneSendToAnUnbootstrappedChainReverts() public {
        SafeTxEvidence memory evidence = _send(_receiverHere(), _payload());
        guard.stage(address(safe), evidence.signedSafeTx.safeTx, evidence.signedSafeTx.signatures);
        vm.expectRevert(abi.encodeWithSelector(TransmitterBase.NotBootstrapped.selector, remote));
        safe.exec(address(st), 0, evidence.signedSafeTx.safeTx.data);
    }

    /// @notice Stage a blob containing a `v = 1` signature entry and attempt to send.
    /// @dev Unsupported source-state-dependent evidence should be rejected before any provider
    ///      fee is spent.
    function test_anApprovedHashEntryRevertsBeforePaying() public {
        _bootstrap();
        SafeTxEvidence memory evidence = _send(_receiverHere(), _payload());
        evidence.signedSafeTx.signatures = abi.encodePacked(
            bytes32(uint256(uint160(vm.addr(1)))), bytes32(0), uint8(1), SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(2)), 0)
        );
        guard.stage(address(safe), evidence.signedSafeTx.safeTx, evidence.signedSafeTx.signatures);
        uint256 sent = mailbox.sentLength();
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.ApprovedHashUnsupported.selector, address(safe)));
        safe.exec(address(st), 0, evidence.signedSafeTx.safeTx.data);
        assertEq(mailbox.sentLength(), sent);
    }

    /* ============================ registration and relay ========================= */

    /// @notice Build an execution leaf with the selected nonce and delivery attributes.
    /// @dev Relay tests need explicit control over both receiver ordering and provider options
    ///      bound into the proof.
    function _execLeaf(uint256 nonce, bytes[] memory attributes) internal view returns (ExecutionLeaf memory l) {
        l.destination = _receiverHere();
        l.nonce = nonce;
        l.validAfter = block.timestamp;
        l.deadline = block.timestamp + 1 days;
        l.calls = _payload();
        l.attributes = attributes;
    }

    /// @notice Build a two-leaf root and its sibling proofs.
    /// @dev Tests can compare distinct leaf relays under one owner-authorized registration.
    function _tree(ExecutionLeaf memory a, ExecutionLeaf memory b)
        internal
        pure
        returns (bytes32 root, bytes32[] memory pa, bytes32[] memory pb)
    {
        bytes32[] memory hashes = new bytes32[](2);
        (hashes[0], hashes[1]) = (DispatchLeaves.hash(a), DispatchLeaves.hash(b));
        return (MerkleBuilder.root(hashes), MerkleBuilder.proof(hashes, 0), MerkleBuilder.proof(hashes, 1));
    }

    /// @notice Sign and execute root registration through the fixture Safe.
    /// @dev Relay tests need both source registration state and the signed evidence that each
    ///      relay must supply.
    function _register(bytes32 root) internal returns (SafeTxEvidence memory evidence) {
        guard.publish(root);
        evidence = _delivery(safe, address(st), abi.encodeCall(ISignedTransmitter.registerRoot, (root)), _quorum());
        safe.exec(address(st), 0, evidence.signedSafeTx.safeTx.data);
    }

    /// @notice Try registration without owner authority, without guard publication and after
    ///         prior registration.
    /// @dev Every root, including zero, must pass the same explicit source authorization and
    ///      uniqueness checks.
    function test_rootRegistrationIsOwnerOnlyPublishedOnlyAndOnce() public {
        vm.prank(address(safe));
        vm.expectRevert(abi.encodeWithSelector(SignedTransmitter.RootNotPublished.selector, bytes32(0)));
        st.registerRoot(bytes32(0));

        guard.publish(bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        st.registerRoot(bytes32(0));

        vm.prank(address(safe));
        st.registerRoot(bytes32(0));
        assertTrue(st.isRootRegistered(bytes32(0)));
        vm.prank(address(safe));
        vm.expectRevert(abi.encodeWithSelector(ISignedTransmitter.RootAlreadyRegistered.selector, bytes32(0)));
        st.registerRoot(bytes32(0));
    }

    /// @notice Supply root registration evidence with nonzero signed transaction value.
    /// @dev Quotes and relays must reject a call that cannot execute against the source's
    ///      nonpayable registration API.
    function test_aValueBearingRegistrationCannotBeQuotedOrRelayed() public {
        _bootstrap();
        ExecutionLeaf memory leaf = _execLeaf(0, new bytes[](0));
        SafeTxEvidence memory evidence = _register(DispatchLeaves.hash(leaf));
        // registerRoot is nonpayable even when called by the owner.
        vm.deal(address(safe), 1);
        vm.expectRevert();
        safe.exec(address(st), 1, evidence.signedSafeTx.safeTx.data);
        evidence.signedSafeTx.safeTx.value = 1;
        evidence.signedSafeTx.signatures = SafeSigs.blob(
            _quorum(), SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, address(safe), block.chainid)
        );
        vm.expectRevert(abi.encodeWithSelector(SignedDispatchCalls.NonzeroRegistrationValue.selector, 1));
        st.quoteRelay(evidence, leaf, new bytes32[](0));
        vm.expectRevert(abi.encodeWithSelector(SignedDispatchCalls.NonzeroRegistrationValue.selector, 1));
        st.relayLeaf(evidence, leaf, new bytes32[](0));
        assertFalse(st.isLeafRelayed(DispatchLeaves.hash(leaf)));
    }

    /// @notice Relay leaves from an ordinary caller and inspect fees, refunds, balance and used
    ///         marks.
    /// @dev Permissionless sending must preserve conduit funds and prevent a second source
    ///      relay of the same leaf.
    function test_anyoneRelaysEachLeafOncePayingTheQuoteWithTheExcessRefunded() public {
        _bootstrap();
        mailbox.setFee(0.01 ether);
        ExecutionLeaf memory a = _execLeaf(0, new bytes[](0));
        ExecutionLeaf memory b = _execLeaf(1, new bytes[](0));
        (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) = _tree(a, b);
        SafeTxEvidence memory registrationEvidence = _register(root);

        uint256 quote = st.quoteRelay(registrationEvidence, a, pa);
        uint256 conduitBefore = address(st).balance;
        address relayer = address(0xF00);
        vm.deal(relayer, 1 ether);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(SignedTransmitter.InsufficientPayment.selector, quote, quote - 1));
        st.relayLeaf{value: quote - 1}(registrationEvidence, a, pa);

        vm.prank(relayer);
        st.relayLeaf{value: quote + 0.5 ether}(registrationEvidence, a, pa);
        assertEq(relayer.balance, 1 ether - quote);
        assertEq(address(st).balance, conduitBefore);
        assertEq(_lastBody(), abi.encode(WIRE_MERKLE, registrationEvidence, a, pa));
        assertTrue(st.isLeafRelayed(DispatchLeaves.hash(a)));

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(SignedTransmitter.LeafAlreadyRelayed.selector, DispatchLeaves.hash(a)));
        st.relayLeaf{value: quote}(registrationEvidence, a, pa);

        vm.prank(relayer);
        st.relayLeaf{value: quote}(registrationEvidence, b, pb);
    }

    /// @notice Price and send a relay with the payer as the provider refund recipient.
    /// @dev A recipient-sensitive fee catches mismatched quote metadata; a delayed refund
    ///      demonstrates that no relay bookkeeping is needed after the send returns.
    function test_providerRefundsBelongToTheRelayerAndQuotesUseItsMetadata() public {
        _bootstrap();
        ExecutionLeaf memory leaf = _execLeaf(0, new bytes[](0));
        SafeTxEvidence memory evidence = _register(DispatchLeaves.hash(leaf));
        address relayer = address(0xF00);
        mailbox.setFee(100);
        mailbox.setRefundSurcharge(relayer, 23);
        mailbox.setRefundSurcharge(address(st), 999);
        vm.deal(relayer, 1000);
        vm.prank(relayer);
        uint256 fee = st.quoteRelay(evidence, leaf, new bytes32[](0));
        assertEq(fee, 123);
        uint256 balanceBefore = address(st).balance;
        vm.prank(relayer);
        st.relayLeaf{value: fee + 10}(evidence, leaf, new bytes32[](0));
        assertEq(mailbox.sent(mailbox.sentLength() - 1).refundTo, relayer);
        assertEq(relayer.balance, 1000 - fee);
        mailbox.refundLater(mailbox.sentLength() - 1, 20);
        assertEq(relayer.balance, 1000 - fee + 20);
        assertEq(address(st).balance, balanceBefore);
    }

    /// @notice Retain the relay lock while a provider refunds the payer directly.
    /// @dev The callback must not reuse the leaf or change prefunded conduit balance.
    function test_directProviderRefundCannotReenterRelay() public {
        _bootstrap();
        mailbox.setFee(100);
        mailbox.setSynchronousRebate(20);
        ExecutionLeaf memory leaf = _execLeaf(0, new bytes[](0));
        SafeTxEvidence memory e = _register(DispatchLeaves.hash(leaf));
        ReenterRefund relayer = new ReenterRefund();
        uint256 balanceBefore = address(st).balance;
        relayer.relay{value: 100}(address(st), abi.encodeCall(st.relayLeaf, (e, leaf, new bytes32[](0))));
        assertTrue(relayer.blocked());
        assertEq(address(relayer).balance, 20);
        assertEq(address(st).balance, balanceBefore);
        assertTrue(st.isLeafRelayed(DispatchLeaves.hash(leaf)));
    }

    /// @notice Try invalid registration signatures, missing registration and altered delivery
    ///         attributes.
    /// @dev A leaf relay needs all three independent checks: valid live authority, local root
    ///      state and exact proof-bound content.
    function test_aRelayIsRefusedForBadEvidenceAnUnregisteredRootOrChangedAttributes() public {
        _bootstrap();
        ExecutionLeaf memory a = _execLeaf(0, new bytes[](0));
        ExecutionLeaf memory b = _execLeaf(1, new bytes[](0));
        (bytes32 root, bytes32[] memory pa,) = _tree(a, b);

        SafeTxEvidence memory unregisteredEvidence =
            _delivery(safe, address(st), abi.encodeCall(ISignedTransmitter.registerRoot, (root)), _quorum());
        vm.expectRevert(abi.encodeWithSelector(SignedTransmitter.RootNotRegistered.selector, root));
        st.relayLeaf{value: 1 ether}(unregisteredEvidence, a, pa);

        SafeTxEvidence memory registrationEvidence = _register(root);
        ExecutionLeaf memory reattributed = _execLeaf(0, new bytes[](1));
        vm.expectRevert(DispatchLeaves.InvalidProof.selector);
        st.relayLeaf{value: 1 ether}(registrationEvidence, reattributed, pa);

        safe.setSignaturesFail(true);
        vm.expectRevert(StubSafe.BadSignatures.selector);
        st.relayLeaf{value: 1 ether}(registrationEvidence, a, pa);
        safe.setSignaturesFail(false);

        SafeTxEvidence memory messageEvidence = _send(_receiverHere(), _payload());
        vm.expectRevert();
        st.relayLeaf{value: 1 ether}(messageEvidence, a, pa);
    }

    /// @notice Relay from a refund-rejecting contract with excess payment.
    /// @dev Refund failure must roll back the send and used-leaf mark rather than consume
    ///      authorization or strand a partial relay.
    function test_aRejectedRefundRevertsTheRelayAndItsMark() public {
        _bootstrap();
        ExecutionLeaf memory a = _execLeaf(0, new bytes[](0));
        ExecutionLeaf memory b = _execLeaf(1, new bytes[](0));
        (bytes32 root, bytes32[] memory pa,) = _tree(a, b);
        SafeTxEvidence memory registrationEvidence = _register(root);
        RefuseEth refuser = new RefuseEth();
        vm.deal(address(this), 1 ether);
        vm.expectRevert(SignedTransmitter.RefundFailed.selector);
        refuser.relay{value: 0.5 ether}(st, registrationEvidence, a, pa);
        assertFalse(st.isLeafRelayed(DispatchLeaves.hash(a)));
    }

    /* ================================ nested evidence ============================= */

    /// @notice Send with an empty child signature payload backed by guard-cached approval
    ///         evidence.
    /// @dev The wire message must include the child authorization the receiver cannot read from
    ///      source storage; missing evidence must fail before payment.
    function test_anEmptyNestedSignatureCarriesTheChildsCachedApproval() public {
        StubSafe child = _safe(_addrs(vm.addr(4), vm.addr(5), vm.addr(6)), 1);
        address[] memory owners = new address[](2);
        (owners[0], owners[1]) = (address(child), vm.addr(1));
        StubSafe parent = new StubSafe();
        parent.setOwners(owners, 2);
        parent.setGuard(address(guard));
        vm.prank(address(parent));
        SignedTransmitter nested = SignedTransmitter(payable(t.createTransmitter(SALT)));
        SafeAuthorityRecord[] memory records = abi.decode(nested.creationRecords(), (SafeAuthorityRecord[]));
        assertEq(records.length, 2);
        assertEq(records[1].safe, address(child));

        BootstrapLeaf memory leaf = BootstrapLeaf(
            Erc7930.encodeEvm(
                REMOTE_CHAIN_ID,
                address(bytes20(t.predictReceiver(remote, address(parent), SALT, nested.authorityGraph())))
            ),
            block.timestamp,
            block.timestamp + 1 days,
            abi.encode(new Call[](0))
        );
        SafeTxEvidence memory evidence;
        evidence.signedSafeTx.safeTx = _safeTx(parent, address(nested), _bootstrapCall(leaf));
        bytes32 h = SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, address(parent), block.chainid);
        evidence.signedSafeTx.signatures =
            SafeSigs.blob(SafeSigs.two(SafeSigs.nested(address(child), ""), SafeSigs.eoa(1)), h);

        // Without the child's cached approval the bootstrap reverts before paying.
        guard.stage(address(parent), evidence.signedSafeTx.safeTx, evidence.signedSafeTx.signatures);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICrossecuteGuard.NestedSafeApprovalNotFound.selector,
                address(child),
                SafeSignaturesUtils.nestedHash(h, address(child), block.chainid)
            )
        );
        parent.exec(address(nested), 0, evidence.signedSafeTx.safeTx.data);

        NestedSafeApproval memory nestedApproval =
            SafeSigs.approval(address(child), h, block.chainid, SafeSigs.one(SafeSigs.eoa(5)), address(0x5161));
        guard.cacheApproval(address(child), nestedApproval.messageHash, nestedApproval.approval);
        vm.deal(address(nested), 1 ether);
        guard.stage(address(parent), evidence.signedSafeTx.safeTx, evidence.signedSafeTx.signatures);
        parent.exec(address(nested), 0, evidence.signedSafeTx.safeTx.data);

        (,,, bytes memory body) = this.decodeSigned(_lastBody());
        SignedBootstrap memory bootstrap = abi.decode(body, (SignedBootstrap));
        assertEq(bootstrap.evidence.nestedApprovals.length, 1);
        assertEq(bootstrap.evidence.nestedApprovals[0].childSafe, address(child));
        assertEq(bootstrap.evidence.nestedApprovals[0].messageHash, nestedApproval.messageHash);
        assertEq(bootstrap.evidence.nestedApprovals[0].approval.signatures, nestedApproval.approval.signatures);
    }
}
