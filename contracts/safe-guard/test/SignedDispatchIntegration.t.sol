// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;
import {GuardTestBase} from "./GuardTestBase.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {SafePolicyGuardBase} from "policy-engine/SafePolicyGuardBase.sol";
import {SafeTx} from "../src/ICrossecuteGuard.sol";
import {SafeHashes} from "../src/SafeHashes.sol";
import {SafeBatchExecutor, ISafeExec} from "../src/SafeBatchExecutor.sol";
import {AuthorityUpdate} from "../src/authority/AuthorityUpdateTypes.sol";
import {AuthorityGraph, AuthorityNode} from "crossecute/messaging/authority/AuthorityGraph.sol";
import {AuthorityUpdateEncoding} from "crossecute/messaging/authority/AuthorityUpdateEncoding.sol";
import {ChildUpdate} from "crossecute/messaging/authority/ChildUpdate.sol";
import {SafeAuthorityGraph} from "crossecute/messaging/signed/SafeAuthorityGraph.sol";
import {SafeAuthorityRecord} from "crossecute/messaging/signed/types/SafeAuthorityTypes.sol";
import {NestedApprovalCollector} from "crossecute/messaging/signed/NestedApprovalCollector.sol";
import {Batch} from "./Batch.sol";
import {TransceiverConfig} from "crossecute/messaging/transceiver/TransceiverCore.sol";
import {TransceiverExtension} from "crossecute/messaging/transceiver/TransceiverExtension.sol";
import {HyperlaneTransceiver} from "crossecute/protocols/hyperlane/HyperlaneTransceiver.sol";
import {HyperlaneTransmitter} from "crossecute/protocols/hyperlane/HyperlaneTransmitter.sol";
import {HyperlaneReceiver} from "crossecute/protocols/hyperlane/HyperlaneReceiver.sol";
import {SignedTransmitter} from "crossecute/messaging/outbound/SignedTransmitter.sol";
import {ISignedTransmitter} from "crossecute/messaging/outbound/ISignedTransmitter.sol";
import {SignedReceiver} from "crossecute/messaging/inbound/SignedReceiver.sol";
import {Call} from "crossecute/messaging/Call.sol";
import {Commitment} from "crossecute/messaging/Commitment.sol";
import {ICommitFinalize, ICancel, ReceiverBase} from "crossecute/messaging/inbound/ReceiverBase.sol";
import {Erc7930} from "crossecute/addressing/Erc7930.sol";
import {ChainKey} from "crossecute/addressing/ChainKey.sol";
import {ChainRegistry} from "crossecute/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "crossecute/registry/IChainRegistryRefs.sol";
import {Provenance} from "crossecute/registry/Provenance.sol";
import {Proxy} from "crossecute/conduit/Proxy.sol";
import {ProxyDeployer, PROXY_DEPLOYER} from "crossecute/conduit/ProxyDeployer.sol";
import {DispatchLeaves} from "crossecute/messaging/signed/DispatchLeaves.sol";
import {SafeQuorum} from "crossecute/messaging/signed/SafeQuorum.sol";
import {
    SafeTxEvidence,
    ExecutionLeaf,
    SignedBootstrap,
    WIRE_STANDALONE
} from "crossecute/messaging/signed/types/SignedDispatchTypes.sol";
import {MockHyperlaneMailbox} from "evm-test/protocols/hyperlane/MockHyperlaneMailbox.sol";
import {unseeded} from "evm-test/RegistrySeed.sol";

/// @notice Records destination effects and supports deliberate failure.
contract IntegrationSink {
    uint256 public hits;
    bool public failing;

    /// @notice Toggle a predictable application failure for rollback tests.
    function setFailing(bool value) external {
        failing = value;
    }

    /// @notice Record one authorized application call.
    function hit() external {
        require(!failing, "destination failure");
        ++hits;
    }
}

/// @notice Real Safe 1.5.0, real guard and real conduits; only transport is mocked.
/// @dev Explicit chain deployments use different recorded deployers so storage can coexist.
///      Cancun compilation here tests integration, not the production Paris gas schedule.
contract SignedDispatchIntegrationTest is GuardTestBase {
    event AuthorityPublished(address indexed sourceSafe, bytes32 indexed updateHead, bytes submission);

    uint256 constant SOURCE = 10;
    uint256 constant BASE = 8453;
    uint256 constant ARBITRUM = 42161;
    uint256 constant KEY_D = 0xD00D;
    bytes32 constant DEPLOY_SALT = keccak256("integration transceiver");
    bytes32 constant USER_SALT = keccak256("integration conduit");
    MockHyperlaneMailbox internal mailbox;
    ChainRegistry internal registry;
    bytes32 internal provider;
    HyperlaneTransceiver internal source;
    mapping(uint256 => HyperlaneTransceiver) internal destination;
    mapping(address => uint256) internal keys;
    mapping(address => bool) internal cached;
    mapping(address => bytes) internal selectedGraphs;
    SignedTransmitter internal st;
    IntegrationSink internal effect;

    /// @notice Deploy a guarded Safe and three independently routed endpoints.
    function setUp() public override {
        vm.chainId(SOURCE);
        super.setUp();
        vm.warp(1_000_000);
        keys[vm.addr(KEY_A)] = KEY_A;
        keys[vm.addr(KEY_B)] = KEY_B;
        keys[vm.addr(KEY_C)] = KEY_C;
        mailbox = new MockHyperlaneMailbox();
        effect = new IntegrationSink();
        registry = new ChainRegistry(address(this), unseeded());
        provider = registry.addMessageProvider("integration");
        registry.setProviderDeployment(provider, DEPLOY_SALT, keccak256(type(Proxy).creationCode));
        // Stateless test deployer at the production address, with this build's proxy bytecode.
        vm.etch(PROXY_DEPLOYER, address(new ProxyDeployer()).code);
        source = _deployChain(SOURCE);
        destination[BASE] = _deployChain(BASE);
        destination[ARBITRUM] = _deployChain(ARBITRUM);
        _route(source, BASE);
        _route(source, ARBITRUM);
        _route(destination[BASE], SOURCE);
        _route(destination[ARBITRUM], SOURCE);
        vm.chainId(SOURCE);
    }

    /// @notice Deploy one genuine provider transceiver and register its derivation inputs.
    function _deployChain(uint256 chain) internal returns (HyperlaneTransceiver t) {
        vm.chainId(chain);
        address impl = address(new HyperlaneTransceiver(address(mailbox), address(new TransceiverExtension())));
        TransceiverConfig memory c;
        c.gateways = new address[](0);
        c.transmitterImplementation = address(new HyperlaneTransmitter(address(mailbox)));
        c.receiverImplementation = address(new HyperlaneReceiver(address(mailbox), address(guard), address(multiSend)));
        c.governorOwner = address(0x5165);
        c.governorHome = Erc7930.encodeEvmChain(SOURCE);
        c.treasury = address(0x7EA5);
        address deployedBy = address(uint160(0xD000 + chain));
        vm.prank(deployedBy);
        t = HyperlaneTransceiver(
            payable(ProxyDeployer(PROXY_DEPLOYER)
                    .deploy(DEPLOY_SALT, impl, abi.encodeCall(HyperlaneTransceiver.initialize, (c, uint32(SOURCE)))))
        );
        bytes32 chainKey = registry.addChainKey(Erc7930.encodeEvmChain(chain), Provenance.Predetermined);
        registry.setCurrentDeployer(deployedBy);
        registry.addProviderOnChain(chainKey, provider, deployedBy);
        registry.markLive(chainKey, provider);
        vm.prank(t.owner());
        TransceiverExtension(address(t))
            .setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Predetermined);
    }

    /// @notice Configure both protocol routing and provider-domain mapping.
    function _route(HyperlaneTransceiver t, uint256 chain) internal {
        vm.startPrank(t.owner());
        TransceiverExtension(address(t)).setRoute(ChainKey.forEvm(chain), Erc7930.encodeEvmChain(chain));
        t.setProviderId(ChainKey.forEvm(chain), uint32(chain));
        vm.stopPrank();
    }

    /// @notice Recursively sign a real Safe quorum in the correct child message domains.
    function _graphSign(Safe account, bytes32 digest) internal view returns (bytes memory out) {
        address[] memory owners = account.getOwners();
        uint256 threshold = account.getThreshold();
        for (uint256 i = 0; i < threshold; ++i) {
            for (uint256 j = i + 1; j < threshold; ++j) {
                if (owners[j] < owners[i]) (owners[i], owners[j]) = (owners[j], owners[i]);
            }
        }
        bytes memory tail;
        for (uint256 i = 0; i < threshold; ++i) {
            uint256 key = keys[owners[i]];
            if (key != 0) {
                (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
                out = abi.encodePacked(out, r, s, v);
            } else {
                bytes memory payload;
                if (!cached[owners[i]]) {
                    payload = _graphSign(
                        Safe(payable(owners[i])), SafeHashes.messageHash(abi.encode(digest), owners[i], SOURCE)
                    );
                }
                out = abi.encodePacked(
                    out, bytes32(uint256(uint160(owners[i]))), bytes32(threshold * 65 + tail.length), uint8(0)
                );
                tail = abi.encodePacked(tail, payload.length, payload);
            }
        }
        return abi.encodePacked(out, tail);
    }

    /// @notice Sign exact calldata at a selected source Safe nonce without executing it.
    function _evidence(address to, bytes memory data, uint256 nonce) internal view returns (SafeTxEvidence memory e) {
        e.signedSafeTx.safeTx.to = to;
        e.signedSafeTx.safeTx.data = data;
        e.signedSafeTx.safeTx.nonce = nonce;
        e.signedSafeTx.signatures =
            _graphSign(safe, SafeHashes.transactionHash(e.signedSafeTx.safeTx, address(safe), SOURCE));
    }

    /// @notice Execute evidence through the real source Safe and guard.
    function _execute(SafeTxEvidence memory e) internal {
        _prepare(e);
        vm.chainId(SOURCE);
        SafeTx memory tx_ = e.signedSafeTx.safeTx;
        assertTrue(
            _execWith(safe, tx_.to, tx_.value, tx_.data, Enum.Operation(tx_.operation), e.signedSafeTx.signatures)
        );
    }

    /// @notice Create and fund the actual signed transmitter through a signed Safe call.
    function _create() internal {
        _activateGraph(safe);
        _execute(_evidence(address(source), abi.encodeCall(source.createTransmitter, (USER_SALT)), safe.nonce()));
        st = SignedTransmitter(
            payable(TransceiverExtension(address(source))
                    .predictConduit(address(safe), USER_SALT, ChainKey.forEvm(SOURCE)))
        );
        assertTrue(st.isSigned());
        vm.deal(address(st), 100 ether);
    }

    /// @notice Predict the signed receiver from the owner and user salt.
    function _receiver(uint256 chain) internal view returns (SignedReceiver) {
        return SignedReceiver(
            payable(address(bytes20(source.predictReceiver(ChainKey.forEvm(chain), address(safe), USER_SALT))))
        );
    }

    /// @notice Encode a variable-size atomic application batch.
    function _calls(uint256 count) internal view returns (bytes memory) {
        Call[] memory calls = new Call[](count);
        for (uint256 i = 0; i < count; ++i) {
            calls[i] = Call(address(effect), 0, abi.encodeCall(effect.hit, ()));
        }
        return abi.encode(calls);
    }

    /// @notice Sign an empty-setup bootstrap of one destination chain.
    function _bootstrapEvidence(uint256 chain) internal view returns (SafeTxEvidence memory) {
        bytes memory body = abi.encode(
            SignedBootstrap(
                address(guard),
                guard.selection(address(safe)).updateHead,
                selectedGraphs[address(safe)],
                st.payloadForCalls(new Call[](0))
            )
        );
        bytes memory payload = st.bootstrapPayload(Erc7930.encodeEvmChain(chain), body);
        return
            _evidence(
                address(st), abi.encodeCall(ISignedTransmitter.bootstrap, (payload, new bytes[](0))), safe.nonce()
            );
    }

    function _liveGraph(Safe account) internal view returns (AuthorityGraph memory graph) {
        SafeAuthorityRecord[] memory records = SafeAuthorityGraph.derive(address(account));
        graph.nodes = new AuthorityNode[](records.length);
        for (uint256 i = 0; i < records.length; ++i) {
            graph.nodes[i] =
                AuthorityNode(records[i], i == 0 ? bytes32(0) : guard.selection(records[i].safe).updateHead);
        }
    }

    function _authorityTransaction(
        Safe account,
        address to,
        bytes memory data,
        Enum.Operation op,
        AuthorityGraph memory graph
    ) internal returns (SafeTxEvidence memory evidence) {
        return _authorityTransaction(account, to, data, op, graph, new ChildUpdate[](0));
    }

    function _authorityTransaction(
        Safe account,
        address to,
        bytes memory data,
        Enum.Operation op,
        AuthorityGraph memory graph,
        ChildUpdate[] memory children
    ) internal returns (SafeTxEvidence memory evidence) {
        Batch.Call[] memory calls;
        (evidence, calls) = _authorityCalls(account, to, data, op, graph, children);
        bytes32 digest = SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, address(account), SOURCE);
        if (to == address(multiSend) || bytes4(data) == guard.selectAuthority.selector) {
            vm.expectEmit(true, true, false, true, address(guard));
            emit AuthorityPublished(address(account), digest, abi.encode(evidence, graph, children));
        }
        batch.run(calls);
        if (to == address(multiSend) || bytes4(data) == guard.selectAuthority.selector) {
            assertEq(
                guard.publishedAuthority(address(account), digest), keccak256(abi.encode(evidence, graph, children))
            );
        } else {
            assertEq(guard.publishedAuthority(address(account), digest), bytes32(0));
        }
        selectedGraphs[address(account)] = abi.encode(graph);
    }

    function _authorityCalls(
        Safe account,
        address to,
        bytes memory data,
        Enum.Operation op,
        AuthorityGraph memory graph,
        ChildUpdate[] memory children
    ) internal returns (SafeTxEvidence memory evidence, Batch.Call[] memory calls) {
        evidence.signedSafeTx.safeTx = _safeTx(account, to, data, op);
        bytes32 digest = SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, address(account), SOURCE);
        _prepareAt(account, digest);
        evidence.signedSafeTx.signatures = _graphSign(account, digest);
        evidence.nestedApprovals =
            NestedApprovalCollector.collect(address(account), digest, evidence.signedSafeTx.signatures);
        AuthorityGraph memory current;
        if (selectedGraphs[address(account)].length != 0) {
            current = abi.decode(selectedGraphs[address(account)], (AuthorityGraph));
        }
        calls = new Batch.Call[](2);
        calls[0] = Batch.Call(
            address(guard),
            abi.encodeCall(
                guard.stageUpdate,
                (address(account), current, graph, children, evidence.signedSafeTx.signatures, evidence.nestedApprovals)
            ),
            false
        );
        calls[1] = Batch.Call(
            address(account),
            abi.encodeCall(
                account.execTransaction,
                (to, 0, data, op, 0, 0, 0, address(0), payable(address(0)), evidence.signedSafeTx.signatures)
            ),
            false
        );
    }

    function _safeTx(Safe account, address to, bytes memory data, Enum.Operation op)
        internal
        view
        returns (SafeTx memory tx_)
    {
        tx_.to = to;
        tx_.data = data;
        tx_.operation = uint8(op);
        tx_.nonce = account.nonce();
    }

    function _activateGraph(Safe root) internal {
        if (guard.selection(address(root)).authorityHash != bytes32(0)) return;
        SafeAuthorityRecord[] memory records = SafeAuthorityGraph.derive(address(root));
        for (uint256 i = 1; i < records.length; ++i) {
            _activateGraph(Safe(payable(records[i].safe)));
        }
        {
            Safe account = root;
            bytes memory data = abi.encodeCall(account.setModuleGuard, (address(guard)));
            bytes32 digest = _txHash(account, address(account), 0, data, Enum.Operation.Call);
            _prepareAt(account, digest);
            assertTrue(_execWith(account, address(account), 0, data, Enum.Operation.Call, _graphSign(account, digest)));
            AuthorityGraph memory graph = _liveGraph(account);
            _authorityTransaction(
                account,
                address(guard),
                abi.encodeCall(guard.activate, (AuthorityUpdateEncoding.graphHash(SOURCE, graph))),
                Enum.Operation.Call,
                graph
            );
        }
    }

    /// @notice Deliver a recorded bootstrap through the authenticated destination handler.
    function _deliverBootstrap(uint256 chain, uint256 index) internal {
        bytes memory body = mailbox.sent(index).body;
        vm.chainId(chain);
        vm.prank(address(mailbox));
        destination[chain].handle(uint32(SOURCE), bytes32(uint256(uint160(address(source)))), body);
        vm.chainId(SOURCE);
    }

    /// @notice Complete source bootstrap and destination initialization.
    function _bootstrap(uint256 chain) internal {
        _execute(_bootstrapEvidence(chain));
        _deliverBootstrap(chain, mailbox.sentLength() - 1);
    }

    /// @notice Sign a standalone send for one destination and explicit Safe nonce.
    function _message(uint256 chain, uint256 nonce) internal view returns (SafeTxEvidence memory) {
        return _evidence(
            address(st),
            abi.encodeCall(
                st.sendMessage, (Erc7930.encodeEvm(chain, address(_receiver(chain))), _calls(1), new bytes[](0))
            ),
            nonce
        );
    }

    /// @notice Deliver a recorded wire bundle through the genuine receiver handler.
    function _deliverMessage(uint256 chain, uint256 index) internal {
        bytes memory body = mailbox.sent(index).body;
        address receiver = address(_receiver(chain));
        vm.chainId(chain);
        vm.prank(address(mailbox));
        HyperlaneReceiver(payable(receiver)).handle(uint32(SOURCE), bytes32(uint256(uint160(address(st)))), body);
        vm.chainId(SOURCE);
    }

    /// @notice Exercise real staging, consumption, provider delivery and shared replay state.
    function test_realSafeStagesAndReceiverExecutesExactlyOnce() public {
        _create();
        _bootstrap(BASE);
        _execute(_message(BASE, safe.nonce()));
        uint256 index = mailbox.sentLength() - 1;
        _deliverMessage(BASE, index);
        _deliverMessage(BASE, index);
        assertEq(effect.hits(), 1);
    }

    function test_aChildRotationNeedsParentAdoptionAndNeverRefreshesBootstrapImplicitly() public {
        Safe child = _selectGraph(1);
        _create();
        _bootstrap(BASE);
        Call[] memory deferred = abi.decode(_calls(1), (Call[]));
        bytes32 pending = Commitment.hashCalls(ChainKey.forEvm(BASE), deferred);
        Call[] memory approvals = new Call[](2);
        approvals[0] = Call(address(_receiver(BASE)), 0, abi.encodeCall(ICommitFinalize.commit, (pending)));
        approvals[1] = approvals[0];
        _execute(
            _evidence(
                address(st),
                abi.encodeCall(
                    st.sendMessage,
                    (Erc7930.encodeEvm(BASE, address(_receiver(BASE))), abi.encode(approvals), new bytes[](0))
                ),
                safe.nonce()
            )
        );
        _deliverMessage(BASE, mailbox.sentLength() - 1);
        assertEq(_receiver(BASE).outstanding(pending), 2);
        bytes32 parentHash = guard.selection(address(safe)).authorityHash;
        AuthorityGraph memory childGraph = _liveGraph(child);
        childGraph.nodes[0].record.threshold = 1;
        Call[] memory mutations = new Call[](1);
        mutations[0] = Call(address(child), 0, abi.encodeCall(child.changeThreshold, (1)));
        SafeTxEvidence memory childEvidence = _authorityTransaction(
            child,
            address(multiSend),
            AuthorityUpdateEncoding.ownershipBatchData(
                address(guard),
                address(child),
                AuthorityUpdate(
                    guard.selection(address(child)).updateHead, AuthorityUpdateEncoding.graphHash(SOURCE, childGraph)
                ),
                mutations
            ),
            Enum.Operation.DelegateCall,
            childGraph
        );
        assertEq(guard.selection(address(safe)).authorityHash, parentHash);
        _bootstrap(ARBITRUM);
        assertEq(_receiver(ARBITRUM).authorityGraph(), parentHash);
        assertEq(_receiver(ARBITRUM).authorityRecords()[1].threshold, 2);

        SafeTxEvidence memory message = _message(BASE, safe.nonce());
        _execute(message);
        uint256 sent = mailbox.sentLength() - 1;
        vm.chainId(BASE);
        SignedReceiver staleReceiver = _receiver(BASE);
        vm.expectRevert();
        staleReceiver.submitMessage(message);
        vm.chainId(SOURCE);

        AuthorityGraph memory next = abi.decode(selectedGraphs[address(safe)], (AuthorityGraph));
        next.nodes[1] = AuthorityNode(childGraph.nodes[0].record, guard.selection(address(child)).updateHead);
        ChildUpdate[] memory children = new ChildUpdate[](1);
        children[0] = ChildUpdate(
            address(child), childEvidence, childGraph.nodes[0].record, AuthorityUpdateEncoding.entries(childGraph)
        );
        SafeTxEvidence memory adoption = _authorityTransaction(
            safe,
            address(guard),
            abi.encodeCall(
                guard.selectAuthority,
                (AuthorityUpdate(
                        guard.selection(address(safe)).updateHead, AuthorityUpdateEncoding.graphHash(SOURCE, next)
                    ))
            ),
            Enum.Operation.Call,
            next,
            children
        );
        for (uint256 i = 0; i < 2; ++i) {
            uint256 chain = i == 0 ? BASE : ARBITRUM;
            vm.chainId(SOURCE);
            bytes memory recipient = Erc7930.encodeEvm(chain, address(_receiver(chain)));
            bytes memory submission = abi.encode(adoption, next, children);
            uint256 fee = st.quoteAuthority(recipient, submission, new bytes[](0));
            // forge-lint: disable-next-line(arbitrary-send-eth) fixture-created transmitter and exact quoted fee
            st.relayAuthority{value: fee}(recipient, submission, new bytes[](0));
            uint256 delivery = mailbox.sentLength() - 1;
            if (i == 0) {
                vm.chainId(chain);
                _receiver(chain).submitAuthority(adoption, next, children);
            }
            _deliverMessage(chain, delivery);
            _deliverMessage(chain, delivery);
            vm.chainId(chain);
            assertEq(_receiver(chain).authorityRecords()[1].threshold, 1);
            assertEq(_receiver(chain).selection().updateHead, guard.selection(address(safe)).updateHead);
        }
        vm.chainId(SOURCE);
        _deliverMessage(BASE, sent);
        assertEq(effect.hits(), 1);
        SignedReceiver baseReceiver = _receiver(BASE);
        vm.chainId(BASE);
        assertEq(baseReceiver.outstanding(pending), 2);
        vm.prank(address(0xBAD));
        baseReceiver.finalize(deferred);
        assertEq(baseReceiver.outstanding(pending), 1);
        assertEq(effect.hits(), 2);
        vm.chainId(SOURCE);
        Call[] memory cancellation = new Call[](1);
        cancellation[0] = Call(address(_receiver(BASE)), 0, abi.encodeCall(ICancel.cancel, (pending)));
        _execute(
            _evidence(
                address(st),
                abi.encodeCall(
                    st.sendMessage,
                    (Erc7930.encodeEvm(BASE, address(_receiver(BASE))), abi.encode(cancellation), new bytes[](0))
                ),
                safe.nonce()
            )
        );
        _deliverMessage(BASE, mailbox.sentLength() - 1);
        vm.chainId(BASE);
        assertEq(baseReceiver.outstanding(pending), 0);
        vm.expectRevert(ReceiverBase.CommitmentMismatch.selector);
        baseReceiver.finalize(deferred);
        vm.chainId(SOURCE);
    }

    /// @notice Rotate an owner of the real Safe, then bootstrap a new chain and dispatch to it.
    /// @dev The new chain stores the rotated graph: a send and a root registration signed by the
    ///      previous quorum are rejected there, by direct submission and provider delivery; the
    ///      new quorum's standalone send and Merkle leaf execute; and the chain bootstrapped
    ///      earlier keeps its graph.
    function test_aChainBootstrappedAfterARotationTrustsTheRotatedOwners() public {
        _create();
        _bootstrap(BASE);
        SafeTxEvidence memory stale = _message(ARBITRUM, safe.nonce() + 1);
        ExecutionLeaf memory leaf = _leaf(ARBITRUM, 0);
        SafeTxEvidence memory staleRegistration = _evidence(
            address(st), abi.encodeCall(ISignedTransmitter.registerRoot, (DispatchLeaves.hash(leaf))), safe.nonce() + 1
        );

        address[] memory owners = safe.getOwners();
        keys[vm.addr(KEY_D)] = KEY_D;
        AuthorityGraph memory next = abi.decode(selectedGraphs[address(safe)], (AuthorityGraph));
        next.nodes[0].record.owners[0].owner = vm.addr(KEY_D);
        Call[] memory mutations = new Call[](1);
        mutations[0] = Call(address(safe), 0, abi.encodeCall(safe.swapOwner, (address(1), owners[0], vm.addr(KEY_D))));
        SafeTxEvidence memory rotation = _authorityTransaction(
            safe,
            address(multiSend),
            AuthorityUpdateEncoding.ownershipBatchData(
                address(guard),
                address(safe),
                AuthorityUpdate(
                    guard.selection(address(safe)).updateHead, AuthorityUpdateEncoding.graphHash(SOURCE, next)
                ),
                mutations
            ),
            Enum.Operation.DelegateCall,
            next
        );
        _bootstrap(ARBITRUM);

        SignedReceiver ra = _receiver(ARBITRUM);
        bytes32 rotated = guard.selection(address(safe)).authorityHash;
        assertEq(ra.authorityGraph(), rotated);
        assertTrue(_receiver(BASE).authorityGraph() != rotated);

        bytes memory notOwner = abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, address(safe), owners[0]);
        vm.chainId(ARBITRUM);
        vm.expectRevert(notOwner);
        ra.submitMessage(stale);
        vm.expectRevert(notOwner);
        ra.submitLeaf(staleRegistration, leaf, new bytes32[](0));
        vm.expectRevert(notOwner);
        vm.prank(address(mailbox));
        HyperlaneReceiver(payable(address(ra)))
            .handle(uint32(SOURCE), bytes32(uint256(uint160(address(st)))), abi.encode(WIRE_STANDALONE, stale));
        vm.chainId(SOURCE);

        _execute(_message(ARBITRUM, safe.nonce()));
        _deliverMessage(ARBITRUM, mailbox.sentLength() - 1);
        assertEq(effect.hits(), 1);

        bytes[] memory leaves = new bytes[](1);
        leaves[0] =
            abi.encode(leaf.destination, leaf.nonce, leaf.validAfter, leaf.deadline, leaf.calls, leaf.attributes);
        bytes32 root = guard.publishLeaves(leaves);
        SafeTxEvidence memory registration =
            _evidence(address(st), abi.encodeCall(ISignedTransmitter.registerRoot, (root)), safe.nonce());
        _execute(registration);
        // forge-lint: disable-next-line(arbitrary-send-eth) the fixture-created transmitter and exact quoted fee
        st.relayLeaf{value: st.quoteLeaf(registration, leaf, new bytes32[](0))}(registration, leaf, new bytes32[](0));
        _deliverMessage(ARBITRUM, mailbox.sentLength() - 1);
        assertEq(effect.hits(), 2);
        bytes memory submission = abi.encode(rotation, next, new ChildUpdate[](0));
        bytes memory recipient = Erc7930.encodeEvm(BASE, address(_receiver(BASE)));
        uint256 fee = st.quoteAuthority(recipient, submission, new bytes[](0));
        // forge-lint: disable-next-line(arbitrary-send-eth) fixture-created transmitter and exact quoted fee
        st.relayAuthority{value: fee}(recipient, submission, new bytes[](0));
        _deliverMessage(BASE, mailbox.sentLength() - 1);
        vm.chainId(BASE);
        assertEq(_receiver(BASE).selection().updateHead, guard.selection(address(safe)).updateHead);
        assertEq(_receiver(BASE).authorityGraph(), rotated);
        vm.chainId(SOURCE);
        _execute(_message(BASE, safe.nonce()));
        _deliverMessage(BASE, mailbox.sentLength() - 1);
        assertEq(effect.hits(), 3);
    }

    /// @notice Direct submission requires neither provider delivery nor source registration.
    function test_directStandaloneAndLeafWhileProviderIsUnavailable() public {
        _create();
        _bootstrap(BASE);
        SafeTxEvidence memory e = _message(BASE, safe.nonce());
        SignedReceiver r = _receiver(BASE);
        vm.chainId(BASE);
        r.submitMessage(e);
        vm.chainId(SOURCE);
        ExecutionLeaf memory leaf = _leaf(BASE, 0);
        e = _evidence(
            address(st), abi.encodeCall(ISignedTransmitter.registerRoot, (DispatchLeaves.hash(leaf))), safe.nonce() + 1
        );
        vm.chainId(BASE);
        r.submitLeaf(e, leaf, new bytes32[](0));
        vm.chainId(SOURCE);
        assertEq(effect.hits(), 2);
        assertFalse(st.isRootRegistered(DispatchLeaves.hash(leaf)));
    }

    /// @notice Build an execution leaf with an independently ordered receiver nonce.
    function _leaf(uint256 chain, uint256 nonce) internal view returns (ExecutionLeaf memory) {
        return ExecutionLeaf(
            Erc7930.encodeEvm(chain, address(_receiver(chain))),
            nonce,
            block.timestamp,
            block.timestamp + 1 days,
            _calls(1),
            new bytes[](0)
        );
    }

    /// @notice Publish a real guard tree, check root parity and relay one leaf per destination.
    function test_realGuardTreeMatchesDispatchLeavesAcrossTwoDestinations() public {
        _create();
        _bootstrap(BASE);
        _bootstrap(ARBITRUM);
        ExecutionLeaf memory a = _leaf(BASE, 0);
        ExecutionLeaf memory b = _leaf(ARBITRUM, 0);
        bytes[] memory leaves = new bytes[](2);
        leaves[0] = abi.encode(a.destination, a.nonce, a.validAfter, a.deadline, a.calls, a.attributes);
        leaves[1] = abi.encode(b.destination, b.nonce, b.validAfter, b.deadline, b.calls, b.attributes);
        bytes32 root = guard.publishLeaves(leaves);
        bytes32 ah = DispatchLeaves.hash(a);
        bytes32 bh = DispatchLeaves.hash(b);
        assertEq(root, ah < bh ? keccak256(abi.encode(ah, bh)) : keccak256(abi.encode(bh, ah)));
        SafeTxEvidence memory e =
            _evidence(address(st), abi.encodeCall(ISignedTransmitter.registerRoot, (root)), safe.nonce());
        _execute(e);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bh;
        // forge-lint: disable-next-line(arbitrary-send-eth) the fixture-created transmitter and exact quoted fee
        st.relayLeaf{value: st.quoteLeaf(e, a, proof)}(e, a, proof);
        _deliverMessage(BASE, mailbox.sentLength() - 1);
        proof[0] = ah;
        // forge-lint: disable-next-line(arbitrary-send-eth) the fixture-created transmitter and exact quoted fee
        st.relayLeaf{value: st.quoteLeaf(e, b, proof)}(e, b, proof);
        _deliverMessage(ARBITRUM, mailbox.sentLength() - 1);
        assertEq(effect.hits(), 2);
    }

    /// @notice Convert separately signed evidence into an atomic source-batch entry.
    function _execution(SafeTxEvidence memory e) internal view returns (SafeBatchExecutor.SafeExecution memory x) {
        x.safe = ISafeExec(address(safe));
        x.to = e.signedSafeTx.safeTx.to;
        x.data = e.signedSafeTx.safeTx.data;
        x.signatures = e.signedSafeTx.signatures;
    }

    /// @notice Batch real sends at nonces 42 and 43 and reject cross-destination submission.
    function test_realConsecutiveSendsAt42And43BindTheirOwnDestinations() public {
        _create();
        _bootstrap(BASE);
        _bootstrap(ARBITRUM);
        vm.store(address(safe), bytes32(uint256(5)), bytes32(uint256(42)));
        SafeTxEvidence memory a = _message(BASE, 42);
        SafeTxEvidence memory b = _message(ARBITRUM, 43);
        SafeBatchExecutor.SafeExecution[] memory xs = new SafeBatchExecutor.SafeExecution[](2);
        xs[0] = _execution(a);
        xs[1] = _execution(b);
        uint256 index = mailbox.sentLength();
        new SafeBatchExecutor().execute(xs);
        assertEq(safe.nonce(), 44);
        SignedReceiver ra = _receiver(BASE);
        SignedReceiver rb = _receiver(ARBITRUM);
        vm.chainId(ARBITRUM);
        vm.expectRevert();
        rb.submitMessage(a);
        vm.chainId(BASE);
        vm.expectRevert();
        ra.submitMessage(b);
        vm.chainId(SOURCE);
        _deliverMessage(BASE, index);
        _deliverMessage(ARBITRUM, index + 1);
        assertEq(effect.hits(), 2);
    }

    /// @notice Roll back both actual provider sends and nonce advances on a second-send failure.
    function test_realBatchRollsBackBothSendsWhenSecondFails() public {
        _create();
        _bootstrap(BASE);
        _bootstrap(ARBITRUM);
        vm.store(address(safe), bytes32(uint256(5)), bytes32(uint256(42)));
        SafeBatchExecutor.SafeExecution[] memory xs = new SafeBatchExecutor.SafeExecution[](2);
        xs[0] = _execution(_message(BASE, 42));
        xs[1] = _execution(_message(ARBITRUM, 43));
        mailbox.setUnrouted(uint32(ARBITRUM));
        uint256 index = mailbox.sentLength();
        uint256 balance = address(st).balance;
        SafeBatchExecutor executor = new SafeBatchExecutor();
        vm.expectRevert();
        executor.execute(xs);
        assertEq(mailbox.sentLength(), index);
        assertEq(safe.nonce(), 42);
        assertEq(address(st).balance, balance);
    }

    /// @notice Install the actual guard and permissive test policies through Safe execution.
    function _installGraph(Safe account) internal {
        bytes memory entries = abi.encodePacked(
            _multiSendEntry(
                address(guard), abi.encodeCall(SafePolicyGuardBase.configureImmediately, (_defaultConfig()))
            ),
            _multiSendEntry(address(account), abi.encodeCall(account.setGuard, (address(guard))))
        );
        bytes memory data = abi.encodeCall(multiSend.multiSend, (entries));
        bytes32 digest = _txHash(account, address(multiSend), 0, data, Enum.Operation.DelegateCall);
        assertTrue(
            _execWith(account, address(multiSend), 0, data, Enum.Operation.DelegateCall, _graphSign(account, digest))
        );
        vm.deal(address(account), 10 ether);
    }

    /// @notice Create an installed 2-of-3 child using the fixture's actual EOA keys.
    function _guardedChild() internal returns (Safe child) {
        child = _newEoaSafe();
        _installGraph(child);
    }

    /// @notice Create an all-children quorum, preserving genuine nested Safe validation.
    function _parent(Safe a, Safe b) internal returns (Safe parent) {
        address[] memory owners = new address[](address(b) == address(0) ? 1 : 2);
        owners[0] = address(a);
        if (owners.length == 2) owners[1] = address(b);
        parent = _newSafe(owners, owners.length);
        _installGraph(parent);
    }

    /// @notice Select the five required owner graphs without mocking Safe signature checks.
    function _selectGraph(uint256 shape) internal returns (Safe child) {
        if (shape == 0) return Safe(payable(address(0)));
        child = _guardedChild();
        if (shape == 3) child = _parent(child, Safe(payable(address(0))));
        if (shape == 4) {
            safe = _parent(_parent(child, Safe(payable(address(0)))), _parent(child, Safe(payable(address(0)))));
        } else {
            safe = _parent(child, Safe(payable(address(0))));
        }
    }

    /// @notice Cache a child's exact signed approval before executing an empty parent entry.
    function _prepare(SafeTxEvidence memory e) internal {
        vm.chainId(SOURCE);
        _prepareAt(safe, SafeHashes.transactionHash(e.signedSafeTx.safeTx, address(safe), SOURCE));
    }

    /// @notice Follow inline paths and approve empty paths in each child's source domain.
    function _prepareAt(Safe account, bytes32 digest) internal {
        address[] memory owners = account.getOwners();
        for (uint256 i = 0; i < account.getThreshold(); ++i) {
            if (keys[owners[i]] != 0) continue;
            Safe child = Safe(payable(owners[i]));
            if (cached[owners[i]]) {
                bytes memory data = abi.encodeCall(signMessageLib.signMessage, (abi.encode(digest)));
                bytes32 approvalHash = _txHash(child, address(signMessageLib), 0, data, Enum.Operation.DelegateCall);
                assertTrue(
                    _execWith(
                        child,
                        address(signMessageLib),
                        0,
                        data,
                        Enum.Operation.DelegateCall,
                        _graphSign(child, approvalHash)
                    )
                );
            } else {
                _prepareAt(child, SafeHashes.messageHash(abi.encode(digest), owners[i], SOURCE));
            }
        }
    }

    /// @notice Collect an actual cached child approval and verify it on the receiver.
    function test_emptyChildSignatureUsesRealGuardCachedEvidence() public {
        Safe child = _selectGraph(2);
        _create();
        cached[address(child)] = true;
        _bootstrap(BASE);
        _execute(_message(BASE, safe.nonce()));
        (, SafeTxEvidence memory e) = abi.decode(mailbox.sent(mailbox.sentLength() - 1).body, (uint256, SafeTxEvidence));
        assertEq(e.nestedApprovals.length, 1);
        assertEq(e.nestedApprovals[0].childSafe, address(child));
        _deliverMessage(BASE, mailbox.sentLength() - 1);
        assertEq(effect.hits(), 1);
    }

    /// @notice Exercise recursive source and destination verification through a shared child.
    function test_sharedChildAndTwoLevelGraphsUseRealSafeDomains() public {
        _selectGraph(4);
        _create();
        _bootstrap(BASE);
        _execute(_message(BASE, safe.nonce()));
        _deliverMessage(BASE, mailbox.sentLength() - 1);
        assertEq(effect.hits(), 1);
    }

    function _measureAuthority(uint256 shape) internal {
        Safe child = _selectGraph(shape);
        _create();
        _bootstrap(BASE);
        AuthorityGraph memory next = abi.decode(selectedGraphs[address(safe)], (AuthorityGraph));
        ChildUpdate[] memory children = new ChildUpdate[](shape == 0 ? 0 : 1);
        address target = address(guard);
        Enum.Operation op = Enum.Operation.Call;
        bytes memory data;
        if (shape == 0) {
            next.nodes[0].record.threshold = 3;
            Call[] memory mutations = new Call[](1);
            mutations[0] = Call(address(safe), 0, abi.encodeCall(safe.changeThreshold, (3)));
            data = AuthorityUpdateEncoding.ownershipBatchData(
                address(guard),
                address(safe),
                AuthorityUpdate(
                    guard.selection(address(safe)).updateHead, AuthorityUpdateEncoding.graphHash(SOURCE, next)
                ),
                mutations
            );
            target = address(multiSend);
            op = Enum.Operation.DelegateCall;
        } else {
            while (keys[child.getOwners()[0]] == 0) child = Safe(payable(child.getOwners()[0]));
            AuthorityGraph memory childGraph = abi.decode(selectedGraphs[address(child)], (AuthorityGraph));
            childGraph.nodes[0].record.threshold = 1;
            Call[] memory mutations = new Call[](1);
            mutations[0] = Call(address(child), 0, abi.encodeCall(child.changeThreshold, (1)));
            SafeTxEvidence memory change = _authorityTransaction(
                child,
                address(multiSend),
                AuthorityUpdateEncoding.ownershipBatchData(
                    address(guard),
                    address(child),
                    AuthorityUpdate(
                        guard.selection(address(child)).updateHead,
                        AuthorityUpdateEncoding.graphHash(SOURCE, childGraph)
                    ),
                    mutations
                ),
                Enum.Operation.DelegateCall,
                childGraph
            );
            children[0] = ChildUpdate(
                address(child), change, childGraph.nodes[0].record, AuthorityUpdateEncoding.entries(childGraph)
            );
            for (uint256 i = 0; i < next.nodes.length; ++i) {
                if (next.nodes[i].record.safe == address(child)) {
                    next.nodes[i] =
                        AuthorityNode(childGraph.nodes[0].record, guard.selection(address(child)).updateHead);
                }
            }
            if (shape == 2) cached[address(child)] = true;
            data = abi.encodeCall(
                guard.selectAuthority,
                (AuthorityUpdate(
                        guard.selection(address(safe)).updateHead, AuthorityUpdateEncoding.graphHash(SOURCE, next)
                    ))
            );
        }
        (SafeTxEvidence memory evidence, Batch.Call[] memory calls) =
            _authorityCalls(safe, target, data, op, next, children);
        emit log_named_uint("authorityShape", shape);
        uint256 g = gasleft();
        batch.run(calls);
        emit log_named_uint("authoritySourceBatchGas", g - gasleft());
        emit log_named_uint("authoritySourceBatchCalldataBytes", abi.encodeCall(batch.run, (calls)).length);
        bytes memory submission = abi.encode(evidence, next, children);
        emit log_named_uint("authoritySubmissionBytes", submission.length);
        bytes memory recipient = Erc7930.encodeEvm(BASE, address(_receiver(BASE)));
        uint256 fee = st.quoteAuthority(recipient, submission, new bytes[](0));
        // forge-lint: disable-next-line(arbitrary-send-eth) fixture transmitter and exact quoted fee
        st.relayAuthority{value: fee}(recipient, submission, new bytes[](0));
        emit log_named_uint("authorityProviderBytes", mailbox.sent(mailbox.sentLength() - 1).body.length);
        _deliverMessage(BASE, mailbox.sentLength() - 1);
        assertEq(_receiver(BASE).selection().authorityHash, AuthorityUpdateEncoding.graphHash(SOURCE, next));
    }

    function test_measureAuthorityEoaRotation() public {
        _measureAuthority(0);
    }

    function test_measureAuthorityNestedAdoption() public {
        _measureAuthority(1);
    }

    function test_measureAuthorityCachedChildAdoption() public {
        _measureAuthority(2);
    }

    function test_measureAuthorityTwoLevelAdoption() public {
        _measureAuthority(3);
    }

    function test_measureAuthoritySharedChildAdoption() public {
        _measureAuthority(4);
    }

    /// @notice Report source operation gas and complete provider sizes for each graph shape.
    /// @dev Includes real Safe/guard execution; mock provider storage is explicitly included.
    function _measure(uint256 shape) internal {
        Safe child = _selectGraph(shape);
        _create();
        if (shape == 2) cached[address(child)] = true;
        emit log_named_uint("shape", shape);
        SafeTxEvidence memory boot = _bootstrapEvidence(BASE);
        _prepare(boot);
        uint256 g = gasleft();
        SafeTx memory tx_ = boot.signedSafeTx.safeTx;
        assertTrue(_execWith(safe, tx_.to, 0, tx_.data, Enum.Operation.Call, boot.signedSafeTx.signatures));
        emit log_named_uint("sourceSafeBootstrapGas", g - gasleft());
        emit log_named_uint("bootstrapEnvelopeBytes", mailbox.sent(mailbox.sentLength() - 1).body.length);
        _deliverBootstrap(BASE, mailbox.sentLength() - 1);
        SafeTxEvidence memory e = _message(BASE, safe.nonce());
        _prepare(e);
        tx_ = e.signedSafeTx.safeTx;
        g = gasleft();
        assertTrue(_execWith(safe, tx_.to, 0, tx_.data, Enum.Operation.Call, e.signedSafeTx.signatures));
        emit log_named_uint("sourceSafeSendGas", g - gasleft());
        emit log_named_uint("standaloneBytes", mailbox.sent(mailbox.sentLength() - 1).body.length);
        _deliverMessage(BASE, mailbox.sentLength() - 1);
        ExecutionLeaf memory leaf = _leaf(BASE, 0);
        bytes[] memory leaves = new bytes[](1);
        leaves[0] =
            abi.encode(leaf.destination, leaf.nonce, leaf.validAfter, leaf.deadline, leaf.calls, leaf.attributes);
        bytes32 root = guard.publishLeaves(leaves);
        e = _evidence(address(st), abi.encodeCall(ISignedTransmitter.registerRoot, (root)), safe.nonce());
        _prepare(e);
        tx_ = e.signedSafeTx.safeTx;
        g = gasleft();
        assertTrue(_execWith(safe, tx_.to, 0, tx_.data, Enum.Operation.Call, e.signedSafeTx.signatures));
        emit log_named_uint("sourceSafeRegisterGas", g - gasleft());
        uint256 fee = st.quoteLeaf(e, leaf, new bytes32[](0));
        g = gasleft();
        // forge-lint: disable-next-line(arbitrary-send-eth) the fixture-created transmitter and exact quoted fee
        st.relayLeaf{value: fee}(e, leaf, new bytes32[](0));
        emit log_named_uint("sourceRelayGas", g - gasleft());
        emit log_named_uint("merkleBytes", mailbox.sent(mailbox.sentLength() - 1).body.length);
        _deliverMessage(BASE, mailbox.sentLength() - 1);
        assertEq(effect.hits(), 2);
    }

    /// @notice Measure the 2-of-3 EOA baseline with real Safe and guard execution.
    function test_measureEoa() public {
        _measure(0);
    }

    /// @notice Measure one inline nested Safe owner.
    function test_measureInline() public {
        _measure(1);
    }

    /// @notice Measure an empty child signature backed by real cached approval evidence.
    function test_measureCached() public {
        _measure(2);
    }

    /// @notice Measure a two-level nested owner graph.
    function test_measureTwoLevel() public {
        _measure(3);
    }

    /// @notice Measure two branches sharing the same nested Safe.
    function test_measureShared() public {
        _measure(4);
    }

    /// @notice Destination out-of-gas leaves a source-accepted leaf retryable by direct submission.
    function test_sourceAcceptedLeafSurvivesDestinationOutOfGasAndRetriesOnce() public {
        _create();
        _bootstrap(BASE);
        ExecutionLeaf memory leaf = _leaf(BASE, 0);
        bytes[] memory leaves = new bytes[](1);
        leaves[0] =
            abi.encode(leaf.destination, leaf.nonce, leaf.validAfter, leaf.deadline, leaf.calls, leaf.attributes);
        bytes32 root = guard.publishLeaves(leaves);
        SafeTxEvidence memory e =
            _evidence(address(st), abi.encodeCall(ISignedTransmitter.registerRoot, (root)), safe.nonce());
        _execute(e);
        // forge-lint: disable-next-line(arbitrary-send-eth) the fixture-created transmitter and exact quoted fee
        st.relayLeaf{value: st.quoteLeaf(e, leaf, new bytes32[](0))}(e, leaf, new bytes32[](0));
        uint256 index = mailbox.sentLength() - 1;
        SignedReceiver r = _receiver(BASE);
        bytes memory data = abi.encodeCall(
            HyperlaneReceiver.handle, (uint32(SOURCE), bytes32(uint256(uint160(address(st)))), mailbox.sent(index).body)
        );
        vm.chainId(BASE);
        vm.prank(address(mailbox));
        // forge-lint: disable-next-line(return-bomb) trusted receiver, deliberately insufficient gas
        (bool ok,) = address(r).call{gas: 20_000}(data);
        assertFalse(ok);
        assertEq(r.nextNonce(), 0);
        assertEq(effect.hits(), 0);
        r.submitLeaf(e, leaf, new bytes32[](0));
        r.submitLeaf(e, leaf, new bytes32[](0));
        assertEq(r.nextNonce(), 1);
        assertEq(effect.hits(), 1);
        vm.chainId(SOURCE);
        assertTrue(st.isLeafRelayed(DispatchLeaves.hash(leaf)));
    }
}
