// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeAuthorityGraph} from "src/messaging/signed/SafeAuthorityGraph.sol";
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
import {HyperlaneReceiver} from "src/protocols/hyperlane/HyperlaneReceiver.sol";
import {Conduits} from "src/conduit/Conduits.sol";
import {SafeAuthorityRecord} from "src/messaging/signed/types/SafeAuthorityTypes.sol";

import {unseeded} from "test/RegistrySeed.sol";
import {toBytes32, ext} from "test/Harness.sol";
import {HyperlaneFixture} from "test/protocols/hyperlane/HyperlaneFixture.sol";
import {Records} from "test/signed/SignedFixtures.sol";
import {StubSafe, StubGuard} from "test/signed/StubSafe.sol";
import {Sink} from "test/signed/SignedReceiver.t.sol";

/// @dev The transceiver's half of signed mode (#108): the mode chosen at creation from the
///      owner's guard, the shared conduit salt, the bootstrap kind held to the conduit's mode,
///      and the destination's checks on a `SIGNED_BOOTSTRAP` before it creates and initializes
///      the receiver.
contract SignedTransceiverTest is HyperlaneFixture {
    bytes32 constant SALT = keccak256("user salt");

    TransceiverBase t;
    bytes32 remote;
    StubSafe safe;
    StubGuard guard;
    Sink sink = new Sink();

    /// @notice Deploy a routed Hyperlane transceiver and a configurable 2-of-3 Safe fixture.
    /// @dev Tests need real conduit creation with controllable source guard compatibility and a
    ///      listed destination chain.
    function setUp() public {
        vm.warp(1_000_000);
        TransceiverConfig memory c = _config();
        c.receiverImplementation = address(new HyperlaneReceiver(address(mailbox), address(0x1234), address(0x5678)));
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

    /// @notice Build the fixture Safe's canonical authority records.
    /// @dev Bootstrap bodies carry these records as the receiver's authority.
    function _records() internal view returns (SafeAuthorityRecord[] memory) {
        return Records.list(Records.record(address(safe), 2, Records.eoaOwners(Records.pks(1, 2, 3))));
    }

    /// @notice Hash the fixture records, as a receiver stores them.
    function _graph() internal view returns (bytes32) {
        return Records.graphHash(REMOTE_CHAIN_ID, _records());
    }

    /* ============================ mode at creation ============================= */

    /// @notice Create a transmitter for a Safe advertising the Crossecute guard interface.
    /// @dev Creation must select signed mode at the address an unsigned conduit of the same owner and
    ///      salt would have.
    function test_aSafeWithACompatibleGuardGetsASignedTransmitter() public {
        safe.setGuard(address(guard));
        vm.prank(address(safe));
        address conduit = t.createTransmitter(SALT);

        SignedTransmitter st = SignedTransmitter(payable(conduit));
        assertEq(st.conduitSalt(), SALT, "the caller's salt is kept");
        assertTrue(st.isSigned());
        assertEq(conduit, ext(address(t)).predictConduit(address(safe), SALT, t.localChainKey()));
    }

    /// @notice A guarded Safe whose owner does not answer as a Safe is refused at creation, as by
    ///         the OFT factory.
    function test_aGuardedSafeWithAnOwnerThatIsNotASafeIsRefusedAtCreation() public {
        address[] memory owners = new address[](2);
        (owners[0], owners[1]) = (vm.addr(1), address(sink));
        safe.setOwners(owners, 2);
        safe.setGuard(address(guard));
        vm.prank(address(safe));
        vm.expectRevert(abi.encodeWithSelector(SafeAuthorityGraph.NotASafe.selector, address(sink)));
        t.createTransmitter(SALT);
    }

    /// @notice Independently derive the signed conduit salt and address.
    /// @dev A signed conduit uses the shared three-field preimage: no address commits to authority.
    function test_aSignedConduitUsesTheSharedSalt() public {
        safe.setGuard(address(guard));
        vm.prank(address(safe));
        address conduit = t.createTransmitter(SALT);
        bytes32 expected = keccak256(abi.encode(address(safe), SALT, t.localChainKey()));
        assertEq(conduit, vm.computeCreate2Address(expected, keccak256(_proxyInitCode()), address(t)));
    }

    /// @notice Return the exact proxy creation bytecode used by the fixture.
    /// @dev Independent CREATE2 address calculations must use the same init-code hash as
    ///      deployment.
    function _proxyInitCode() internal pure returns (bytes memory) {
        return type(ProxyForHash).creationCode;
    }

    /// @notice Create conduits for unsupported guard and owner cases.
    /// @dev Capability discovery must fail safely to unsigned mode rather than assuming signed
    ///      compatibility.
    function test_noGuardAnIncompatibleGuardOrAnEoaGetUnsignedMode() public {
        vm.prank(address(safe));
        assertEq(SignedTransmitter(payable(t.createTransmitter(SALT))).isSigned(), false);

        guard.setAdvertises(false);
        safe.setGuard(address(guard));
        vm.prank(address(safe));
        assertEq(SignedTransmitter(payable(t.createTransmitter(keccak256("2")))).isSigned(), false);

        vm.prank(address(0xE0A));
        assertEq(SignedTransmitter(payable(t.createTransmitter(SALT))).isSigned(), false);
    }

    /// @notice Change the source guard after creating a conduit.
    /// @dev Mode and address are creation-time choices and must not change when the owner's
    ///      guard changes later.
    function test_aGuardChangeAfterCreationKeepsTheMode() public {
        safe.setGuard(address(guard));
        vm.prank(address(safe));
        SignedTransmitter st = SignedTransmitter(payable(t.createTransmitter(SALT)));
        safe.setGuard(address(0));
        assertTrue(st.isSigned());
        vm.prank(address(safe));
        vm.expectRevert();
        st.sendMessage(Erc7930.encodeEvm(REMOTE_CHAIN_ID, address(st)), hex"00", new bytes[](0));
    }

    /// @notice Vary the user salt and the source threshold independently.
    /// @dev The user salt separates conduits; an authority change does not move the address.
    function test_theUserSaltMovesTheAddressAndTheThresholdDoesNot() public {
        safe.setGuard(address(guard));
        vm.prank(address(safe));
        address a = t.createTransmitter(SALT);
        vm.prank(address(safe));
        address b = t.createTransmitter(keccak256("other"));
        assertTrue(a != b);

        address[] memory owners = new address[](3);
        (owners[0], owners[1], owners[2]) = (vm.addr(1), vm.addr(2), vm.addr(3));
        safe.setOwners(owners, 3);
        assertEq(ext(address(t)).predictConduit(address(safe), SALT, t.localChainKey()), a);
    }

    /* ============================== inbound bootstrap ============================ */

    /// @notice Predict the local receiver address from the fixture's source owner and salt.
    function _receiver() internal view returns (address) {
        return ext(address(t)).predictConduit(address(safe), SALT, remote);
    }

    /// @notice Build a signed bootstrap body from setup calls and authority records.
    function _body(bytes memory setup, SafeAuthorityRecord[] memory records) internal pure returns (bytes memory) {
        return Records.bootstrap(address(0x1234), records, setup);
    }

    /// @notice Encode one tagged sink call for receiver initialization.
    /// @dev A visible effect shows whether setup ran, repeated or rolled back during receiver
    ///      creation.
    function _setup(bytes memory tag) internal view returns (bytes memory) {
        Call[] memory c = new Call[](1);
        c[0] = Call(address(sink), 0, abi.encodeCall(Sink.hit, (tag)));
        return abi.encode(c);
    }

    /// @notice Deliver a signed bootstrap envelope through the configured mock provider.
    /// @dev This exercises transceiver inbound derivation and receiver initialization as one
    ///      operation.
    function _send(address transmitter, bytes memory body) internal {
        _deliver(
            address(t),
            _remoteProviderId(),
            toBytes32(address(t)),
            Envelope.encodeSignedBootstrap(address(safe), SALT, toBytes32(transmitter), body)
        );
    }

    /// @notice Deliver a valid signed bootstrap and inspect the receiver and setup effects.
    /// @dev Address derivation, authority storage and authorized setup must agree in the
    ///      complete destination creation path.
    function test_aSignedBootstrapCreatesAndInitializesTheDerivedReceiver() public {
        address r = _receiver();
        _send(r, _body(_setup("go"), _records()));
        assertEq(SignedReceiver(payable(r)).authorityGraph(), _graph());
        assertEq(SignedReceiver(payable(r)).sourceTransmitter(), r);
        assertEq(sink.hits(), 1);
    }

    /// @notice Deliver a second signed bootstrap for an existing receiver.
    /// @dev Creation is single-shot: the second delivery reverts and changes nothing.
    function test_aSecondBootstrapRefuses() public {
        address r = _receiver();
        _send(r, _body(_setup("go"), _records()));
        vm.expectPartialRevert(Conduits.ConduitExists.selector);
        _send(r, _body(_setup("other"), _records()));
        assertEq(sink.hits(), 1);
    }

    /// @notice Carry a source transmitter other than the one derived for the owner and salt.
    /// @dev The destination binds the signed receiver to the shared derivation of its transmitter.
    function test_aBootstrapNamingAnotherTransmitterRefuses() public {
        address r = _receiver();
        vm.expectRevert(abi.encodeWithSelector(TransceiverCore.SourceTransmitterMismatch.selector, r, address(0xBAD)));
        _send(address(0xBAD), _body(_setup("go"), _records()));
        assertEq(r.code.length, 0);
    }

    /* ============================== outbound bootstrap =========================== */

    /// @notice Send each bootstrap kind from a conduit in the other mode.
    /// @dev Both modes share an address, so the source transceiver holds the envelope kind to the
    ///      conduit's mode.
    function test_aBootstrapKindMustMatchTheConduitMode() public {
        safe.setGuard(address(guard));
        vm.prank(address(safe));
        address signedConduit = t.createTransmitter(SALT);
        vm.prank(address(0xE0A));
        address unsignedConduit = t.createTransmitter(SALT);

        vm.prank(signedConduit);
        vm.expectRevert(abi.encodeWithSelector(TransceiverCore.BootstrapModeMismatch.selector, signedConduit));
        t.bootstrap(remote, address(safe), SALT, new Call[](0), new bytes[](0));

        vm.prank(signedConduit);
        vm.expectRevert(abi.encodeWithSelector(TransceiverCore.BootstrapModeMismatch.selector, signedConduit));
        t.bootstrapElements(remote, address(safe), SALT, new bytes[](0), new bytes[](0));

        vm.prank(unsignedConduit);
        vm.expectRevert(abi.encodeWithSelector(TransceiverCore.BootstrapModeMismatch.selector, unsignedConduit));
        t.bootstrapSigned(remote, address(0xE0A), SALT, hex"", new bytes[](0));
    }

    /// @notice Make signed receiver setup revert during transceiver delivery.
    /// @dev Receiver deployment and initialization must roll back together instead of leaving a
    ///      partially configured conduit.
    function test_aRevertingSetupLeavesTheReceiverUndeployed() public {
        address r = _receiver();
        Call[] memory c = new Call[](1);
        c[0] = Call(address(sink), 0, abi.encodeCall(Sink.boom, ()));
        vm.expectRevert();
        _send(r, _body(abi.encode(c), _records()));
        assertEq(r.code.length, 0);
    }
}

/// @dev Exposes `Proxy`'s initcode for the salt-preimage check.
import {Proxy as ProxyForHash} from "src/conduit/Proxy.sol";
