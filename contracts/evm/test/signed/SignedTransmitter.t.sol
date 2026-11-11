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
import {SignedTransmitter} from "src/messaging/signed/SignedTransmitter.sol";
import {SignedTransmitterLogic} from "src/messaging/signed/SignedTransmitterLogic.sol";
import {SignedCalls} from "src/messaging/signed/SignedCalls.sol";
import {SafeSignatures} from "src/messaging/signed/SafeSignatures.sol";
import {DispatchLeaves} from "src/messaging/signed/DispatchLeaves.sol";
import {ISignedOwnerCalls} from "src/messaging/signed/ISignedOwnerCalls.sol";
import {
    SafeRecord,
    ExecutionLeaf,
    BootstrapLeaf,
    SignedDelivery,
    SignedBootstrap,
    NestedApproval,
    ISignedTransmitter,
    WIRE_STANDALONE,
    WIRE_MERKLE
} from "src/messaging/signed/ISignedDispatch.sol";
import {unseeded} from "test/RegistrySeed.sol";
import {ext} from "test/Harness.sol";
import {HyperlaneFixture} from "test/protocols/hyperlane/HyperlaneFixture.sol";
import {MerkleBuilder, SafeSigs, Sig} from "test/signed/SignedFixtures.sol";
import {StubSafe, StubGuard} from "test/signed/StubSafe.sol";

/// @notice Rejects every refund, to show a failed refund reverts the relay.
contract RefuseEth {
    function relay(SignedTransmitter st, SignedDelivery memory d, ExecutionLeaf memory l, bytes32[] memory p)
        external
        payable
    {
        st.relayLeaf{value: msg.value}(d, l, p);
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

    function _safe(address[] memory owners, uint256 threshold) internal returns (StubSafe s) {
        s = new StubSafe();
        s.setOwners(owners, threshold);
        s.setGuard(address(guard));
    }

    function _addrs(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function _quorum() internal pure returns (Sig[] memory) {
        return SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(2));
    }

    function _safeTx(StubSafe s, address to, bytes memory data) internal returns (SafeTx memory safeTx) {
        safeTx.to = to;
        safeTx.data = data;
        safeTx.nonce = ++safeNonce;
        s;
    }

    function _delivery(StubSafe s, address to, bytes memory data, Sig[] memory sigs)
        internal
        returns (SignedDelivery memory d)
    {
        d.safeTx = _safeTx(s, to, data);
        d.signatures = SafeSigs.blob(sigs, SafeHashes.transactionHash(d.safeTx, address(s), block.chainid));
    }

    /// @dev The guard's pre-hook stages the signed transaction; the Safe then calls its target.
    function _exec(StubSafe s, SignedDelivery memory d) internal {
        guard.stage(address(s), d.safeTx, d.signatures);
        s.exec(d.safeTx.to, 0, d.safeTx.data);
    }

    function _receiverHere() internal view returns (bytes memory) {
        return Erc7930.encodeEvm(REMOTE_CHAIN_ID, _receiverAddress());
    }

    function _receiverAddress() internal view returns (address) {
        return address(bytes20(t.predictReceiver(remote, address(safe), SALT, st.authorityGraph())));
    }

    function _bootstrapCall(BootstrapLeaf memory leaf) internal pure returns (bytes memory) {
        bytes memory payload = abi.encode(DispatchLeaves.hash(leaf), uint256(0), leaf, new bytes32[](0));
        return abi.encodeCall(ISignedOwnerCalls.bootstrap, (payload, new bytes[](0)));
    }

    function _leaf() internal view returns (BootstrapLeaf memory) {
        return BootstrapLeaf(_receiverHere(), block.timestamp, block.timestamp + 1 days, abi.encode(new Call[](0)));
    }

    function _lastBody() internal view returns (bytes memory) {
        return mailbox.sent(mailbox.sentLength() - 1).body;
    }

    function _bootstrap() internal returns (SignedDelivery memory d) {
        d = _delivery(safe, address(st), _bootstrapCall(_leaf()), _quorum());
        _exec(safe, d);
    }

    /* ================================== bootstrap ================================ */

    function test_aSignedBootstrapCarriesTheSignedCallAndTheCreationRecords() public {
        SignedDelivery memory d = _bootstrap();
        (address owner, bytes32 salt, bytes32 transmitter, bytes memory body) = this.decodeSigned(_lastBody());
        assertEq(owner, address(safe));
        assertEq(salt, SALT);
        assertEq(transmitter, bytes32(uint256(uint160(address(st)))));
        SignedBootstrap memory b = abi.decode(body, (SignedBootstrap));
        assertEq(b.delivery.safeTx.data, d.safeTx.data);
        assertEq(b.delivery.signatures, d.signatures);
        assertEq(keccak256(abi.encode(b.records)), st.authorityGraph());
        assertTrue(st.isBootstrapped(remote));
        assertEq(st.destinationReceiverOn(remote), abi.encodePacked(_receiverAddress()));
        assertEq(st.pendingBootstrap(remote), bytes32(0));
    }

    function decodeSigned(bytes calldata m) external pure returns (address, bytes32, bytes32, bytes memory) {
        return Envelope.decodeSignedBootstrap(m);
    }

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

    function test_aNewSignedBootstrapReplacesAPendingOne() public {
        mailbox.setFee(2 ether);
        _bootstrap();
        bytes32 first = st.pendingBootstrap(remote);
        _bootstrap();
        assertTrue(st.pendingBootstrap(remote) != first);
    }

    function test_aBootstrapWithoutAStagedRecordReverts() public {
        bytes memory data = _bootstrapCall(_leaf());
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.NoLiveRecord.selector, address(safe)));
        safe.exec(address(st), 0, data);
    }

    function test_aBootstrapForAnotherReceiverOrPastItsDeadlineReverts() public {
        BootstrapLeaf memory leaf = _leaf();
        leaf.destination = Erc7930.encodeEvm(REMOTE_CHAIN_ID, address(0xBAD));
        SignedDelivery memory d = _delivery(safe, address(st), _bootstrapCall(leaf), _quorum());
        guard.stage(address(safe), d.safeTx, d.signatures);
        vm.expectRevert(abi.encodeWithSelector(SignedTransmitterLogic.WrongBootstrapTarget.selector, leaf.destination));
        safe.exec(address(st), 0, d.safeTx.data);

        leaf = _leaf();
        leaf.deadline = block.timestamp - 1;
        leaf.validAfter = block.timestamp - 2;
        d = _delivery(safe, address(st), _bootstrapCall(leaf), _quorum());
        guard.stage(address(safe), d.safeTx, d.signatures);
        vm.expectRevert(abi.encodeWithSelector(SignedCalls.WindowClosed.selector, leaf.validAfter, leaf.deadline));
        safe.exec(address(st), 0, d.safeTx.data);
    }

    function test_onlyTheOwnerBootstrapsAndOwnershipIsFixed() public {
        bytes memory data = _bootstrapCall(_leaf());
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        (bool ok,) = address(st).call(data);
        assertTrue(ok, "expectRevert");

        vm.prank(address(safe));
        vm.expectRevert(SignedTransmitter.OwnershipFixed.selector);
        st.transferOwnership(address(0x1));
    }

    /* ================================= standalone ================================ */

    function _send(bytes memory recipient, bytes memory payload) internal returns (SignedDelivery memory d) {
        d = _delivery(
            safe,
            address(st),
            abi.encodeCall(IERC7786GatewaySource.sendMessage, (recipient, payload, new bytes[](0))),
            _quorum()
        );
    }

    function _payload() internal pure returns (bytes memory) {
        Call[] memory c = new Call[](1);
        c[0] = Call(address(0xCAFE), 0, hex"01");
        return abi.encode(c);
    }

    function test_aStandaloneSendWrapsTheExactSignedCallAndPaysItsQuote() public {
        _bootstrap();
        mailbox.setFeePerByte(10);
        SignedDelivery memory d = _send(_receiverHere(), _payload());
        uint256 quote = st.quoteSignedMessage(d);
        uint256 before = address(st).balance;
        _exec(safe, d);

        assertEq(_lastBody(), abi.encode(WIRE_STANDALONE, d));
        assertEq(before - address(st).balance, quote);
        assertEq(quote, 10 * abi.encode(WIRE_STANDALONE, d).length);
    }

    function test_thePlainQuotesRefuseInSignedMode() public {
        bytes memory recipient = _receiverHere();
        vm.expectRevert(SignedTransmitter.SignedQuoteRequired.selector);
        st.quoteMessage(recipient, _payload(), new bytes[](0));
        vm.expectRevert(SignedTransmitter.SignedQuoteRequired.selector);
        st.quoteBootstrap(hex"00", new bytes[](0));
    }

    function test_aStandaloneSendToAnUnbootstrappedChainReverts() public {
        SignedDelivery memory d = _send(_receiverHere(), _payload());
        guard.stage(address(safe), d.safeTx, d.signatures);
        vm.expectRevert(abi.encodeWithSelector(TransmitterBase.NotBootstrapped.selector, remote));
        safe.exec(address(st), 0, d.safeTx.data);
    }

    function test_anApprovedHashEntryRevertsBeforePaying() public {
        _bootstrap();
        SignedDelivery memory d = _send(_receiverHere(), _payload());
        d.signatures = abi.encodePacked(
            bytes32(uint256(uint160(vm.addr(1)))), bytes32(0), uint8(1), SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(2)), 0)
        );
        guard.stage(address(safe), d.safeTx, d.signatures);
        uint256 sent = mailbox.sentLength();
        vm.expectRevert(abi.encodeWithSelector(SafeSignatures.ApprovedHashUnsupported.selector, address(safe)));
        safe.exec(address(st), 0, d.safeTx.data);
        assertEq(mailbox.sentLength(), sent);
    }

    /* ============================ registration and relay ========================= */

    function _execLeaf(uint256 nonce, bytes[] memory attributes) internal view returns (ExecutionLeaf memory l) {
        l.destination = _receiverHere();
        l.nonce = nonce;
        l.validAfter = block.timestamp;
        l.deadline = block.timestamp + 1 days;
        l.calls = _payload();
        l.attributes = attributes;
    }

    function _tree(ExecutionLeaf memory a, ExecutionLeaf memory b)
        internal
        pure
        returns (bytes32 root, bytes32[] memory pa, bytes32[] memory pb)
    {
        bytes32[] memory hashes = new bytes32[](2);
        (hashes[0], hashes[1]) = (DispatchLeaves.hash(a), DispatchLeaves.hash(b));
        return (MerkleBuilder.root(hashes), MerkleBuilder.proof(hashes, 0), MerkleBuilder.proof(hashes, 1));
    }

    function _register(bytes32 root) internal returns (SignedDelivery memory d) {
        guard.publish(root);
        d = _delivery(safe, address(st), abi.encodeCall(ISignedOwnerCalls.registerRoot, (root)), _quorum());
        safe.exec(address(st), 0, d.safeTx.data);
    }

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

    function test_anyoneRelaysEachLeafOncePayingTheQuoteWithTheExcessRefunded() public {
        _bootstrap();
        mailbox.setFee(0.01 ether);
        ExecutionLeaf memory a = _execLeaf(0, new bytes[](0));
        ExecutionLeaf memory b = _execLeaf(1, new bytes[](0));
        (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) = _tree(a, b);
        SignedDelivery memory reg = _register(root);

        uint256 quote = st.quoteRelay(reg, a, pa);
        uint256 conduitBefore = address(st).balance;
        address relayer = address(0xF00);
        vm.deal(relayer, 1 ether);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(SignedTransmitter.InsufficientPayment.selector, quote, quote - 1));
        st.relayLeaf{value: quote - 1}(reg, a, pa);

        vm.prank(relayer);
        st.relayLeaf{value: quote + 0.5 ether}(reg, a, pa);
        assertEq(relayer.balance, 1 ether - quote);
        assertEq(address(st).balance, conduitBefore);
        assertEq(_lastBody(), abi.encode(WIRE_MERKLE, reg, a, pa));
        assertTrue(st.isLeafRelayed(DispatchLeaves.hash(a)));

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(SignedTransmitter.LeafAlreadyRelayed.selector, DispatchLeaves.hash(a)));
        st.relayLeaf{value: quote}(reg, a, pa);

        vm.prank(relayer);
        st.relayLeaf{value: quote}(reg, b, pb);
    }

    function test_aRelayIsRefusedForBadEvidenceAnUnregisteredRootOrChangedAttributes() public {
        _bootstrap();
        ExecutionLeaf memory a = _execLeaf(0, new bytes[](0));
        ExecutionLeaf memory b = _execLeaf(1, new bytes[](0));
        (bytes32 root, bytes32[] memory pa,) = _tree(a, b);

        SignedDelivery memory unregistered =
            _delivery(safe, address(st), abi.encodeCall(ISignedOwnerCalls.registerRoot, (root)), _quorum());
        vm.expectRevert(abi.encodeWithSelector(SignedTransmitter.RootNotRegistered.selector, root));
        st.relayLeaf{value: 1 ether}(unregistered, a, pa);

        SignedDelivery memory reg = _register(root);
        ExecutionLeaf memory reattributed = _execLeaf(0, new bytes[](1));
        vm.expectRevert(DispatchLeaves.InvalidProof.selector);
        st.relayLeaf{value: 1 ether}(reg, reattributed, pa);

        safe.setSignaturesFail(true);
        vm.expectRevert(StubSafe.BadSignatures.selector);
        st.relayLeaf{value: 1 ether}(reg, a, pa);
        safe.setSignaturesFail(false);

        SignedDelivery memory asSend = _send(_receiverHere(), _payload());
        vm.expectRevert();
        st.relayLeaf{value: 1 ether}(asSend, a, pa);
    }

    function test_aRejectedRefundRevertsTheRelayAndItsMark() public {
        _bootstrap();
        ExecutionLeaf memory a = _execLeaf(0, new bytes[](0));
        ExecutionLeaf memory b = _execLeaf(1, new bytes[](0));
        (bytes32 root, bytes32[] memory pa,) = _tree(a, b);
        SignedDelivery memory reg = _register(root);
        RefuseEth refuser = new RefuseEth();
        vm.deal(address(this), 1 ether);
        vm.expectRevert(SignedTransmitter.RefundFailed.selector);
        refuser.relay{value: 0.5 ether}(st, reg, a, pa);
        assertFalse(st.isLeafRelayed(DispatchLeaves.hash(a)));
    }

    /* ================================ nested evidence ============================= */

    function test_anEmptyNestedSignatureCarriesTheChildsCachedApproval() public {
        StubSafe child = _safe(_addrs(vm.addr(4), vm.addr(5), vm.addr(6)), 1);
        address[] memory owners = new address[](2);
        (owners[0], owners[1]) = (address(child), vm.addr(1));
        StubSafe parent = new StubSafe();
        parent.setOwners(owners, 2);
        parent.setGuard(address(guard));
        vm.prank(address(parent));
        SignedTransmitter nested = SignedTransmitter(payable(t.createTransmitter(SALT)));
        SafeRecord[] memory records = abi.decode(nested.creationRecords(), (SafeRecord[]));
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
        SignedDelivery memory d;
        d.safeTx = _safeTx(parent, address(nested), _bootstrapCall(leaf));
        bytes32 h = SafeHashes.transactionHash(d.safeTx, address(parent), block.chainid);
        d.signatures = SafeSigs.blob(SafeSigs.two(SafeSigs.nested(address(child), ""), SafeSigs.eoa(1)), h);

        // Without the child's cached approval the bootstrap reverts before paying.
        guard.stage(address(parent), d.safeTx, d.signatures);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICrossecuteGuard.ApprovalNotFound.selector,
                address(child),
                SafeSignatures.nestedHash(h, address(child), block.chainid)
            )
        );
        parent.exec(address(nested), 0, d.safeTx.data);

        NestedApproval memory a =
            SafeSigs.approval(address(child), h, block.chainid, SafeSigs.one(SafeSigs.eoa(5)), address(0x5161));
        guard.cacheApproval(address(child), a.messageHash, a.approval);
        vm.deal(address(nested), 1 ether);
        guard.stage(address(parent), d.safeTx, d.signatures);
        parent.exec(address(nested), 0, d.safeTx.data);

        (,,, bytes memory body) = this.decodeSigned(_lastBody());
        SignedBootstrap memory b = abi.decode(body, (SignedBootstrap));
        assertEq(b.delivery.nestedApprovals.length, 1);
        assertEq(b.delivery.nestedApprovals[0].childSafe, address(child));
        assertEq(b.delivery.nestedApprovals[0].messageHash, a.messageHash);
        assertEq(b.delivery.nestedApprovals[0].approval.signatures, a.approval.signatures);
    }
}
