// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;
import {GuardTestBase} from "./GuardTestBase.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {SafePolicyGuard} from "policy-engine/SafePolicyGuard.sol";
import {SafeTx} from "../src/ICrossecuteGuard.sol";
import {SafeHashes} from "../src/SafeHashes.sol";
import {SafeBatchExecutor, ISafeExec} from "../src/SafeBatchExecutor.sol";
import {TransceiverConfig} from "crossecute/messaging/transceiver/TransceiverCore.sol";
import {TransceiverExtension} from "crossecute/messaging/transceiver/TransceiverExtension.sol";
import {HyperlaneTransceiver} from "crossecute/protocols/hyperlane/HyperlaneTransceiver.sol";
import {HyperlaneTransmitter} from "crossecute/protocols/hyperlane/HyperlaneTransmitter.sol";
import {HyperlaneReceiver} from "crossecute/protocols/hyperlane/HyperlaneReceiver.sol";
import {SignedTransmitter} from "crossecute/messaging/outbound/SignedTransmitter.sol";
import {ISignedTransmitter} from "crossecute/messaging/outbound/ISignedTransmitter.sol";
import {SignedReceiver} from "crossecute/messaging/inbound/SignedReceiver.sol";
import {Call} from "crossecute/messaging/Call.sol";
import {Erc7930} from "crossecute/addressing/Erc7930.sol";
import {ChainKey} from "crossecute/addressing/ChainKey.sol";
import {ChainRegistry} from "crossecute/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "crossecute/registry/IChainRegistryRefs.sol";
import {Provenance} from "crossecute/registry/Provenance.sol";
import {Proxy} from "crossecute/conduit/Proxy.sol";
import {ProxyDeployer, PROXY_DEPLOYER} from "crossecute/conduit/ProxyDeployer.sol";
import {DispatchLeaves} from "crossecute/messaging/signed/DispatchLeaves.sol";
import {SafeAuthorityRecord} from "crossecute/messaging/signed/types/SafeAuthorityTypes.sol";
import {
    SafeTxEvidence,
    ExecutionLeaf,
    BootstrapLeaf,
    SignedBootstrap
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
    uint256 constant SOURCE = 10;
    uint256 constant BASE = 8453;
    uint256 constant ARBITRUM = 42161;
    bytes32 constant DEPLOY_SALT = keccak256("integration transceiver");
    bytes32 constant USER_SALT = keccak256("integration conduit");
    MockHyperlaneMailbox internal mailbox;
    ChainRegistry internal registry;
    bytes32 internal provider;
    HyperlaneTransceiver internal source;
    mapping(uint256 => HyperlaneTransceiver) internal destination;
    mapping(address => uint256) internal keys;
    mapping(address => bool) internal cached;
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
        c.receiverImplementation = address(new HyperlaneReceiver(address(mailbox)));
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
        t.setDomain(ChainKey.forEvm(chain), uint32(chain));
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
        _execute(_evidence(address(source), abi.encodeCall(source.createTransmitter, (USER_SALT)), safe.nonce()));
        bytes32 graph = keccak256(TransceiverExtension(address(source)).signedAuthority(address(safe)));
        st = SignedTransmitter(
            payable(TransceiverExtension(address(source))
                    .predictConduit(address(safe), USER_SALT, ChainKey.forEvm(SOURCE), graph))
        );
        assertTrue(st.authorityGraph() != bytes32(0));
        vm.deal(address(st), 100 ether);
    }

    /// @notice Predict the signed receiver using retained creation records.
    function _receiver(uint256 chain) internal view returns (SignedReceiver) {
        return SignedReceiver(
            payable(address(
                    bytes20(
                        source.predictReceiver(ChainKey.forEvm(chain), address(safe), USER_SALT, st.authorityGraph())
                    )
                ))
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

    /// @notice Sign an empty-setup bootstrap for one derived receiver.
    function _bootstrapEvidence(uint256 chain) internal view returns (SafeTxEvidence memory) {
        BootstrapLeaf memory leaf = BootstrapLeaf(
            Erc7930.encodeEvm(chain, address(_receiver(chain))), block.timestamp, block.timestamp + 1 days, _calls(0)
        );
        return _evidence(
            address(st),
            abi.encodeCall(
                ISignedTransmitter.bootstrap,
                (abi.encode(DispatchLeaves.hash(leaf), uint256(0), leaf, new bytes32[](0)), new bytes[](0))
            ),
            safe.nonce()
        );
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

    /// @notice Accept signed bootstrap before its source Safe transaction executes.
    function test_bootstrapCanArriveBeforeSourceExecution() public {
        _create();
        SafeTxEvidence memory e = _bootstrapEvidence(BASE);
        bytes memory body = abi.encode(SignedBootstrap(e, abi.decode(st.creationRecords(), (SafeAuthorityRecord[]))));
        uint256 nonce = safe.nonce();
        vm.chainId(BASE);
        vm.prank(address(mailbox));
        destination[BASE].handle(
            uint32(SOURCE),
            bytes32(uint256(uint160(address(source)))),
            abi.encode(uint8(4), address(safe), USER_SALT, bytes32(uint256(uint160(address(st)))), body)
        );
        vm.chainId(SOURCE);
        assertEq(safe.nonce(), nonce);
        assertEq(_receiver(BASE).authorityGraph(), st.authorityGraph());
        _execute(e);
        _deliverBootstrap(BASE, mailbox.sentLength() - 1);
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
        st.relayLeaf{value: st.quoteRelay(e, a, proof)}(e, a, proof);
        _deliverMessage(BASE, mailbox.sentLength() - 1);
        proof[0] = ah;
        // forge-lint: disable-next-line(arbitrary-send-eth) the fixture-created transmitter and exact quoted fee
        st.relayLeaf{value: st.quoteRelay(e, b, proof)}(e, b, proof);
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
            _multiSendEntry(address(guard), abi.encodeCall(SafePolicyGuard.configureImmediately, (_defaultConfig()))),
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
        uint256 fee = st.quoteRelay(e, leaf, new bytes32[](0));
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
        st.relayLeaf{value: st.quoteRelay(e, leaf, new bytes32[](0))}(e, leaf, new bytes32[](0));
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
