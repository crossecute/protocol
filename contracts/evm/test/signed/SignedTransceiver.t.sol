// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {TransceiverCore} from "src/messaging/transceiver/TransceiverCore.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {Call} from "src/messaging/Call.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {SignedReceiver} from "src/messaging/inbound/SignedReceiver.sol";
import {SignedTransmitter} from "src/messaging/outbound/SignedTransmitter.sol";
import {SafeAuthorityGraph} from "src/messaging/signed/SafeAuthorityGraph.sol";
import {DispatchLeaves} from "src/messaging/signed/DispatchLeaves.sol";
import {ISignedTransmitter} from "src/messaging/outbound/ISignedTransmitter.sol";
import {SafeAuthorityRecord} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {BootstrapLeaf, SafeTxEvidence, SignedBootstrap} from "src/messaging/signed/types/SignedDispatchTypes.sol";

import {unseeded} from "test/RegistrySeed.sol";
import {toBytes32, ext} from "test/Harness.sol";
import {HyperlaneFixture} from "test/protocols/hyperlane/HyperlaneFixture.sol";
import {SafeSigs, Records} from "test/signed/SignedFixtures.sol";
import {StubSafe, StubGuard} from "test/signed/StubSafe.sol";
import {Sink} from "test/signed/SignedReceiver.t.sol";

/// @dev The transceiver's half of signed mode (#108): the mode chosen at creation from the
///      owner's guard, the graph in the conduit salt, and the destination's checks on a
///      `SIGNED_BOOTSTRAP` before it creates and initializes the receiver.
contract SignedTransceiverTest is HyperlaneFixture {
    bytes32 constant SALT = keccak256("user salt");

    TransceiverBase t;
    bytes32 remote;
    StubSafe safe;
    StubGuard guard;
    Sink sink = new Sink();

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

        safe = new StubSafe();
        address[] memory owners = new address[](3);
        (owners[0], owners[1], owners[2]) = (vm.addr(1), vm.addr(2), vm.addr(3));
        safe.setOwners(owners, 2);
        guard = new StubGuard();
    }

    function _records() internal view returns (SafeAuthorityRecord[] memory) {
        return Records.list(Records.record(address(safe), 2, Records.eoaOwners(Records.pks(1, 2, 3))));
    }

    function _graph() internal view returns (bytes32) {
        return SafeAuthorityGraph.hash(_records());
    }

    /* ============================ mode at creation ============================= */

    function test_aSafeWithACompatibleGuardGetsASignedTransmitter() public {
        safe.setGuard(address(guard));
        vm.prank(address(safe));
        address conduit = t.createTransmitter(SALT);

        SignedTransmitter st = SignedTransmitter(payable(conduit));
        assertEq(st.authorityGraph(), _graph());
        assertEq(st.creationRecords(), abi.encode(_records()));
        assertEq(st.conduitSalt(), SALT, "the caller's salt is kept");
        assertEq(conduit, ext(address(t)).predictConduit(address(safe), SALT, t.localChainKey(), _graph()));
        assertTrue(conduit != ext(address(t)).predictConduit(address(safe), SALT, t.localChainKey()));
    }

    function test_theSignedSaltIsTheFourFieldPreimage() public {
        safe.setGuard(address(guard));
        vm.prank(address(safe));
        address conduit = t.createTransmitter(SALT);
        bytes32 expected = keccak256(abi.encode(address(safe), SALT, t.localChainKey(), _graph()));
        assertEq(conduit, vm.computeCreate2Address(expected, keccak256(_proxyInitCode()), address(t)));
    }

    function _proxyInitCode() internal pure returns (bytes memory) {
        return type(ProxyForHash).creationCode;
    }

    function test_noGuardAnIncompatibleGuardOrAnEoaGetPlain() public {
        vm.prank(address(safe));
        assertEq(SignedTransmitter(payable(t.createTransmitter(SALT))).authorityGraph(), bytes32(0));

        guard.setAdvertises(false);
        safe.setGuard(address(guard));
        vm.prank(address(safe));
        assertEq(SignedTransmitter(payable(t.createTransmitter(keccak256("2")))).authorityGraph(), bytes32(0));

        vm.prank(address(0xE0A));
        assertEq(SignedTransmitter(payable(t.createTransmitter(SALT))).authorityGraph(), bytes32(0));
    }

    function test_aGuardChangeAfterCreationKeepsTheMode() public {
        safe.setGuard(address(guard));
        vm.prank(address(safe));
        SignedTransmitter st = SignedTransmitter(payable(t.createTransmitter(SALT)));
        safe.setGuard(address(0));
        assertEq(st.authorityGraph(), _graph());
        vm.prank(address(safe));
        vm.expectRevert();
        st.sendMessage(Erc7930.encodeEvm(REMOTE_CHAIN_ID, address(st)), hex"00", new bytes[](0));
    }

    function test_userSaltAndThresholdEachMoveTheAddress() public {
        safe.setGuard(address(guard));
        vm.prank(address(safe));
        address a = t.createTransmitter(SALT);
        vm.prank(address(safe));
        address b = t.createTransmitter(keccak256("other"));
        assertTrue(a != b);

        address[] memory owners = new address[](3);
        (owners[0], owners[1], owners[2]) = (vm.addr(1), vm.addr(2), vm.addr(3));
        safe.setOwners(owners, 3);
        vm.prank(address(safe));
        address c = t.createTransmitter(SALT);
        assertTrue(c != a);
    }

    /* ============================== inbound bootstrap ============================ */

    /// @dev The conduit homed on `remote` sits at the same address here: one transceiver
    ///      address, Ethereum's CREATE2 on both chains.
    function _receiver(bytes32 graph) internal view returns (address) {
        return ext(address(t)).predictConduit(address(safe), SALT, remote, graph);
    }

    function _body(address receiver, address target, bytes memory setup, SafeAuthorityRecord[] memory records)
        internal
        view
        returns (bytes memory)
    {
        BootstrapLeaf memory leaf = BootstrapLeaf(
            Erc7930.encodeEvm(block.chainid, receiver), block.timestamp, block.timestamp + 1 days, setup
        );
        bytes memory payload = abi.encode(DispatchLeaves.hash(leaf), uint256(0), leaf, new bytes32[](0));
        SafeTxEvidence memory evidence;
        evidence.signedSafeTx.safeTx.to = target;
        evidence.signedSafeTx.safeTx.data = abi.encodeCall(ISignedTransmitter.bootstrap, (payload, new bytes[](0)));
        evidence.signedSafeTx.signatures = SafeSigs.blob(
            SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(2)),
            SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, address(safe), REMOTE_CHAIN_ID)
        );
        return abi.encode(SignedBootstrap(evidence, records));
    }

    function _setup(bytes memory tag) internal view returns (bytes memory) {
        Call[] memory c = new Call[](1);
        c[0] = Call(address(sink), 0, abi.encodeCall(Sink.hit, (tag)));
        return abi.encode(c);
    }

    function _send(address transmitter, bytes memory body) internal {
        _deliver(
            address(t),
            _remoteProviderId(),
            toBytes32(address(t)),
            Envelope.encodeSignedBootstrap(address(safe), SALT, toBytes32(transmitter), body)
        );
    }

    function test_aSignedBootstrapCreatesAndInitializesTheDerivedReceiver() public {
        address r = _receiver(_graph());
        _send(r, _body(r, r, _setup("go"), _records()));
        assertEq(SignedReceiver(payable(r)).authorityGraph(), _graph());
        assertEq(SignedReceiver(payable(r)).sourceTransmitter(), r);
        assertEq(sink.hits(), 1);
    }

    function test_aRepeatIsSilentAndADifferentLeafRefuses() public {
        address r = _receiver(_graph());
        bytes memory body = _body(r, r, _setup("go"), _records());
        _send(r, body);
        _send(r, body);
        assertEq(sink.hits(), 1);

        vm.expectPartialRevert(SignedReceiver.NotTheBootstrap.selector);
        _send(r, _body(r, r, _setup("other"), _records()));
    }

    function test_substitutedRecordsDeriveAnotherTransmitter() public {
        address r = _receiver(_graph());
        SafeAuthorityRecord[] memory otherRecords =
            Records.list(Records.record(address(safe), 1, Records.eoaOwners(Records.pks(1, 2, 3))));
        address otherTransmitter = _receiver(SafeAuthorityGraph.hash(otherRecords));
        vm.expectRevert(abi.encodeWithSelector(TransceiverCore.SourceTransmitterMismatch.selector, otherTransmitter, r));
        _send(r, _body(r, r, _setup("go"), otherRecords));
    }

    function test_aPlainBootstrapNamingTheSignedTransmitterCreatesNothingThere() public {
        address r = _receiver(_graph());
        address plain = ext(address(t)).predictConduit(address(safe), SALT, remote);
        vm.expectRevert(abi.encodeWithSelector(TransceiverCore.SourceTransmitterMismatch.selector, plain, r));
        _deliver(
            address(t),
            _remoteProviderId(),
            toBytes32(address(t)),
            Envelope.encodeBootstrap(address(safe), SALT, toBytes32(r), new Call[](0))
        );
        assertEq(r.code.length, 0);
        _send(r, _body(r, r, _setup("go"), _records()));
        assertEq(SignedReceiver(payable(r)).authorityGraph(), _graph());
    }

    function test_aRevertingSetupLeavesTheReceiverUndeployed() public {
        address r = _receiver(_graph());
        Call[] memory c = new Call[](1);
        c[0] = Call(address(sink), 0, abi.encodeCall(Sink.boom, ()));
        vm.expectRevert();
        _send(r, _body(r, r, abi.encode(c), _records()));
        assertEq(r.code.length, 0);
    }

    function test_aBootstrapSignedForAnotherTargetRefuses() public {
        address r = _receiver(_graph());
        vm.expectRevert();
        _send(r, _body(r, address(0xBAD), _setup("go"), _records()));
        assertEq(r.code.length, 0);
    }
}

/// @dev Exposes `Proxy`'s initcode for the salt-preimage check.
import {Proxy as ProxyForHash} from "src/conduit/Proxy.sol";
