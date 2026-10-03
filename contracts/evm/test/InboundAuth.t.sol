// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Envelope} from "src/messaging/Envelope.sol";
import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {UnsendableHub, UnsendableSpoke, UnsendableTransmitter, homeTransmitterFor} from "test/Unsendable.sol";

contract MockReceiver is ReceiverBase {
    /// @dev A harness trusts any gateway, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }

    uint256 public executedCount;

    function isAllowed(address, bytes4) public pure override returns (bool) {
        return true;
    }

    function _execute(Call[] memory calls) internal override {
        executedCount += calls.length;
    }
}

/// @dev Stands in for a protocol adapter: translates an SDK callback into the three
///      arguments `_onInbound` takes, and does nothing else. Authentication is not its job.
/// @dev A transmitter with an inert send, so an account can be stood up on a destination
///      without a provider behind it. A report has to land on a real account now.
contract Transmitter is UnsendableTransmitter {
    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256)
        internal
        pure
        override
        returns (bytes32)
    {
        return bytes32(0);
    }

    /// @dev A harness trusts any gateway, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

contract Hub is UnsendableHub {
    function initialize(address owner_, address impl) external initializer {
        __HubTransceiverBase_init(owner_, address(0), new address[](0), impl);
    }

    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256)
        internal
        pure
        override
        returns (bytes32)
    {
        return bytes32(0);
    }

    /// @dev The account prices its bootstrap before sending it.
    function _quoteMessage(bytes memory, bytes memory, bytes[] memory) internal pure override returns (uint256) {
        return 0;
    }

    function arrive(bytes memory route, bytes memory sender, bytes calldata message) external {
        _onInbound(route, sender, message);
    }

    /// @dev A harness trusts any gateway, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

contract Spoke is UnsendableSpoke {
    function initialize(address, address impl, bytes calldata home) external initializer {
        __SpokeTransceiverBase_init(
            new address[](0),
            impl,
            ChainKey.forEvm(1),
            Erc7930.encodeEvmChain(1),
            home,
            address(0x7EA5),
            bytes32(0),
            false
        );
    }

    function arrive(bytes memory route, bytes memory sender, bytes calldata message) external {
        _onInbound(route, sender, message);
    }

    /// @dev A harness trusts any gateway, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

contract InboundAuthTest is Test {
    Hub hub;
    Spoke spoke;
    ChainRegistry registry;

    address msig = address(0x5165);
    address transmitter = address(0x7A11);
    bytes32 provider;

    bytes HOME_SENDER = abi.encodePacked(address(0xB0B0));
    bytes HOME_ROUTE = Erc7930.encodeEvmChain(1);

    function setUp() public {
        registry = ChainRegistry(
            address(new ERC1967Proxy(address(new ChainRegistry()), abi.encodeCall(ChainRegistry.initialize, (msig))))
        );
        address impl = address(new MockReceiver());
        hub = new Hub();
        hub.initialize(msig, address(new Transmitter()));
        spoke = new Spoke();
        spoke.initialize(msig, impl, HOME_SENDER);

        vm.startPrank(msig);
        provider = registry.addMessageProvider("layerzero");
        hub.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Attested);
        registry.setLocalTransceiver(provider, address(hub));
        vm.stopPrank();
    }

    /* ================================== spoke ================================== */

    /// @dev One origin, so it is a comparison. No registry, no lookup that could return
    ///      the wrong answer if configuration drifted.
    function test_spokeAcceptsTheHubAndStandsTheReceiverUp() public {
        spoke.arrive(HOME_ROUTE, HOME_SENDER, _bootstrapMsg());

        MockReceiver r = MockReceiver(payable(spoke.predictCrossAccount(transmitter, bytes32(0), spoke.homeChainKey())));
        assertEq(
            r.sourceTransmitter(),
            homeTransmitterFor(spoke, transmitter, bytes32(0)),
            "its peer is the carried transmitter"
        );
        assertEq(r.executedCount(), 1, "and its payload ran on arrival");
    }

    /// @dev A sibling spoke sending from a chain the hub also talks to is still not the
    ///      hub. Both halves of the check are load-bearing.
    function test_spokeRejectsTheRightRouteFromTheWrongSender() public {
        bytes memory msg_ = _bootstrapMsg();
        vm.expectRevert(SpokeTransceiverBase.NotHomeOrigin.selector);
        spoke.arrive(HOME_ROUTE, abi.encodePacked(address(0xBAD)), msg_);
    }

    function test_spokeRejectsTheRightSenderFromTheWrongRoute() public {
        bytes memory msg_ = _bootstrapMsg();
        vm.expectRevert(SpokeTransceiverBase.NotHomeOrigin.selector);
        spoke.arrive(Erc7930.encodeEvmChain(8453), HOME_SENDER, msg_);
    }

    /// @dev A receiver may call its spoke, but a hub creates no receivers and would refuse a
    ///      bootstrap envelope on arrival, after the fee was spent, so neither the send nor its
    ///      quote runs.
    function test_aSpokeRefusesAnOutboundBootstrap() public {
        spoke.arrive(HOME_ROUTE, HOME_SENDER, _bootstrapMsg());
        address receiver = spoke.predictCrossAccount(transmitter, bytes32(0), spoke.homeChainKey());
        bytes32 home = ChainKey.forEvm(1);

        // The receiver is homed elsewhere, so the caller check refuses it first: only an
        // account homed on this chain may bootstrap from it.
        vm.deal(receiver, 1 ether);
        vm.prank(receiver);
        vm.expectRevert(
            abi.encodeWithSelector(TransceiverBase.NotTheAccount.selector, transmitter, bytes32(0), receiver)
        );
        spoke.bootstrap{value: 1 ether}(home, transmitter, bytes32(0), _boot(), new bytes[](0));

        // An account homed here passes that check, and the spoke still refuses.
        address local = spoke.predictCrossAccount(transmitter, bytes32(0), spoke.localChainKey());
        vm.deal(local, 1 ether);
        vm.prank(local);
        vm.expectRevert(SpokeTransceiverBase.NoOutboundBootstrap.selector);
        spoke.bootstrap{value: 1 ether}(home, transmitter, bytes32(0), _boot(), new bytes[](0));

        vm.prank(local);
        vm.expectRevert(SpokeTransceiverBase.NoOutboundBootstrap.selector);
        spoke.bootstrapElements(home, transmitter, bytes32(0), new bytes[](1), new bytes[](0));

        vm.expectRevert(SpokeTransceiverBase.NoOutboundBootstrap.selector);
        spoke.quoteBootstrap(home, transmitter, bytes32(0), _boot(), new bytes[](0));
        vm.expectRevert(SpokeTransceiverBase.NoOutboundBootstrap.selector);
        spoke.quoteBootstrapElements(home, transmitter, bytes32(0), new bytes[](1), new bytes[](0));
    }

    /// @dev There is no setter by which a spoke could be made to accept a second origin.
    ///      The set of chains that can drive it is fixed at deployment.
    function test_spokeOriginCannotBeWidenedByAnyone() public {
        (bool a,) = address(spoke).call(abi.encodeWithSignature("setHomeTransceiver(bytes)", HOME_SENDER));
        assertFalse(a);
        (bool b,) =
            address(spoke).call(abi.encodeWithSignature("setRouting(address,bytes32,uint8)", address(0), bytes32(0), 0));
        assertFalse(b, "a spoke has no routing to set either");
    }

    /* =================================== hub =================================== */

    function _wireSpokeChain(uint32, uint256 chainId, address counterpart) internal returns (bytes32 chainKey) {
        vm.startPrank(msig);
        chainKey = registry.addChainKey(Erc7930.encodeEvmChain(chainId));
        // A chain that reports is one this contract cannot derive an account on: `eip155`
        // graded below `Derived` is the zkSync and Tron shape.
        registry.setProvenance(chainKey, Provenance.Attested);
        hub.setCounterpart(chainKey, Erc7930.encodeEvm(chainId, counterpart));
        vm.stopPrank();
        vm.prank(msig);
        // The route is the chain identifier now, so `keccak256(route) == chainKey`.
        hub.setRoute(chainKey, Erc7930.encodeEvmChain(chainId));
        vm.startPrank(msig);
        vm.stopPrank();
    }

    /// @dev N origins, so it is a lookup. The route names the chain and the registry names
    ///      that chain's counterpart; the report is recorded against the chain the route
    ///      resolved to, not one the message claimed.
    function test_hubResolvesTheOriginAndRecordsTheReport() public {
        address counterpart = address(0xC0DE);
        bytes32 baseKey = _wireSpokeChain(30184, 8453, counterpart);
        Transmitter acct = _standUpAccount(8453);

        bytes memory interop = Erc7930.encodeEvm(8453, address(0xBEEF));
        hub.arrive(
            Erc7930.encodeEvmChain(8453),
            abi.encodePacked(counterpart),
            Envelope.encodeReceiverReport(transmitter, bytes32(0), interop)
        );

        assertEq(
            acct.counterpartOn(baseKey),
            abi.encodePacked(address(0xBEEF)),
            "recorded against the chain the ROUTE resolved to"
        );
    }

    /// @dev The account is what the report writes to now, so it has to exist and to have
    ///      been stood up on that destination.
    function _standUpAccount(uint256 chainId) internal returns (Transmitter acct) {
        vm.startPrank(transmitter);
        acct = Transmitter(payable(hub.createTransmitter(bytes32(0))));
        acct.bootstrap(chainId, new Call[](0), new bytes[](0));
        vm.stopPrank();
    }

    function test_hubRejectsAnUnknownRoute() public {
        bytes memory m = Envelope.encodeReceiverReport(transmitter, bytes32(0), bytes(""));
        vm.expectRevert(OutboundBase.UnknownRoute.selector);
        hub.arrive(abi.encode(uint32(99999)), abi.encodePacked(address(0xC0DE)), m);
    }

    /// @dev A known chain speaking with the wrong contract is refused. Without this, any
    ///      contract on a registered chain could report receiver addresses.
    function test_hubRejectsAKnownRouteFromTheWrongSender() public {
        bytes32 baseKey = _wireSpokeChain(30184, 8453, address(0xC0DE));
        bytes memory m = Envelope.encodeReceiverReport(transmitter, bytes32(0), bytes(""));

        vm.expectRevert(abi.encodeWithSelector(HubTransceiverBase.NotCounterpart.selector, baseKey));
        hub.arrive(Erc7930.encodeEvmChain(8453), abi.encodePacked(address(0xBAD)), m);
    }

    /// @dev The provenance bar gates the inbound path too. A chain whose counterpart is
    ///      only `Attested` cannot drive a hub that demands `Derived`, however well-formed
    ///      its message is.
    function test_hubProvenanceBarAppliesToInbound() public {
        address counterpart = address(0xC0DE);
        vm.startPrank(msig);
        bytes32 chainKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        vm.stopPrank();
        vm.prank(msig);
        hub.setRoute(chainKey, Erc7930.encodeEvmChain(8453));

        // Graded `Attested`: the chain's addresses cannot be recomputed here, so any
        // claim about them is worth exactly the bridge that carried it.
        vm.startPrank(msig);
        registry.setProvenance(chainKey, Provenance.Attested);
        hub.setCounterpart(chainKey, Erc7930.encodeEvm(8453, counterpart));
        vm.stopPrank();
        _standUpAccount(8453);

        // At the weakest bar the message is accepted.
        bytes memory report =
            Envelope.encodeReceiverReport(transmitter, bytes32(0), Erc7930.encodeEvm(8453, address(0xBEEF)));
        hub.arrive(Erc7930.encodeEvmChain(8453), abi.encodePacked(counterpart), report);

        // Raise it, and the same well-formed message from the same contract is refused.
        vm.prank(msig);
        hub.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Derived);
        bytes memory report2 =
            Envelope.encodeReceiverReport(transmitter, bytes32(0), Erc7930.encodeEvm(8453, address(0xBEEF)));
        vm.expectRevert(
            abi.encodeWithSelector(
                HubTransceiverBase.InsufficientCounterpartProvenance.selector, chainKey, Provenance.Attested
            )
        );
        hub.arrive(Erc7930.encodeEvmChain(8453), abi.encodePacked(counterpart), report2);
    }

    /* ================================= envelope ================================ */

    /// @dev Every envelope leads with its kind, and each side refuses a kind it does not act
    ///      on before reading anything else, so a wrong shape is refused by name rather than
    ///      misread.
    function test_aHubRefusesABootstrapEnvelope() public {
        _wireSpokeChain(30184, 8453, address(0xC0DE));
        bytes memory wrongWay = _bootstrapMsg();

        vm.expectRevert(
            abi.encodeWithSelector(
                Envelope.UnexpectedEnvelopeKind.selector, Envelope.RECEIVER_REPORT, Envelope.BOOTSTRAP
            )
        );
        hub.arrive(Erc7930.encodeEvmChain(8453), abi.encodePacked(address(0xC0DE)), wrongWay);
    }

    function test_aSpokeRefusesAReportEnvelope() public {
        bytes memory wrongWay =
            Envelope.encodeReceiverReport(transmitter, bytes32(0), Erc7930.encodeEvm(1, transmitter));

        vm.expectRevert(
            abi.encodeWithSelector(
                Envelope.UnexpectedEnvelopeKind.selector, Envelope.BOOTSTRAP, Envelope.RECEIVER_REPORT
            )
        );
        spoke.arrive(HOME_ROUTE, HOME_SENDER, wrongWay);
    }

    /// @dev The elements form is for a non-EVM transceiver; an EVM one has no decoder for it.
    function test_anEvmSpokeRefusesTheElementsForm() public {
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"01";
        bytes memory wrongWay = Envelope.encodeBootstrapElements(transmitter, bytes32(0), _homeTransmitter(), elements);

        vm.expectRevert(
            abi.encodeWithSelector(
                Envelope.UnexpectedEnvelopeKind.selector, Envelope.BOOTSTRAP, Envelope.BOOTSTRAP_ELEMENTS
            )
        );
        spoke.arrive(HOME_ROUTE, HOME_SENDER, wrongWay);
    }

    /// @dev A v1 body led with the owner, not a kind. Kinds start at 1, so the owner word is
    ///      refused as an unknown kind rather than decoded.
    function test_anUntaggedV1BodyIsRefused() public {
        bytes memory v1 = abi.encode(transmitter, bytes32(0), _boot());

        vm.expectRevert(abi.encodeWithSelector(Envelope.UnknownEnvelopeKind.selector, uint256(uint160(transmitter))));
        spoke.arrive(HOME_ROUTE, HOME_SENDER, v1);
    }

    /// @dev Shorter than the word that holds the kind.
    function test_aTruncatedEnvelopeIsRefused() public {
        bytes memory truncated = new bytes(31);
        truncated[30] = 0x01;

        vm.expectRevert(Envelope.EnvelopeTooShort.selector);
        spoke.arrive(HOME_ROUTE, HOME_SENDER, truncated);
    }

    function testFuzz_onlyDefinedKindsAreRead(uint256 kind) public {
        vm.assume(kind == 0 || kind > Envelope.RECEIVER_REPORT);
        bytes memory m = abi.encode(kind, transmitter, bytes32(0), _boot());

        vm.expectRevert(abi.encodeWithSelector(Envelope.UnknownEnvelopeKind.selector, kind));
        this.peekBootstrap(m);
    }

    function testFuzz_bootstrapEnvelopeRoundTrips(address t_, bytes32 src, address target, bytes memory data)
        public
        view
    {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: target, value: 3, data: data});

        (address gotT,, bytes32 gotSrc, Call[] memory got) =
            this.peekBootstrap(Envelope.encodeBootstrap(t_, bytes32(0), src, calls));

        assertEq(gotT, t_);
        assertEq(gotSrc, src, "the transmitter crosses as the origin's own bytes");
        assertEq(got.length, 1);
        assertEq(got[0].target, target);
        assertEq(got[0].value, 3);
        assertEq(got[0].data, data);
    }

    /// @dev Every provider prices per byte, so the transmitter is a fixed word: a dynamic
    ///      `bytes` field would add an offset and a length word to every bootstrap as well.
    function test_theTransmitterCostsOneWord() public view {
        bytes memory withTransmitter = Envelope.encodeBootstrap(transmitter, bytes32(0), _homeTransmitter(), _boot());
        bytes memory without = abi.encode(Envelope.BOOTSTRAP, transmitter, bytes32(0), _boot());
        assertEq(withTransmitter.length, without.length + 32);
    }

    function peekBootstrap(bytes calldata m) external pure returns (address, bytes32, bytes32, Call[] memory) {
        return Envelope.decodeBootstrap(m);
    }

    /// @dev The transmitter a hub would carry for `transmitter`'s account.
    function _homeTransmitter() internal view returns (bytes32) {
        return bytes32(uint256(uint160(homeTransmitterFor(spoke, transmitter, bytes32(0)))));
    }

    function _bootstrapMsg() internal view returns (bytes memory) {
        return Envelope.encodeBootstrap(transmitter, bytes32(0), _homeTransmitter(), _boot());
    }

    /// @dev The transmitter is not derived here: the receiver answers to whatever address the
    ///      authenticated bootstrap carried. An EVM receiver can only answer to an EVM one.
    function test_aBootstrapMustCarryAnEvmTransmitter() public {
        bytes32 wide = bytes32(uint256(0xBEEF) << 160);
        bytes memory m = Envelope.encodeBootstrap(transmitter, bytes32(0), wide, _boot());

        vm.expectRevert(abi.encodeWithSelector(SpokeTransceiverBase.SourceTransmitterNotEvm.selector, wide));
        spoke.arrive(HOME_ROUTE, HOME_SENDER, m);
    }

    function test_theReceiverAnswersToTheCarriedTransmitter() public {
        address carried = address(0x5EC0);
        spoke.arrive(
            HOME_ROUTE,
            HOME_SENDER,
            Envelope.encodeBootstrap(transmitter, bytes32(0), bytes32(uint256(uint160(carried))), _boot())
        );

        MockReceiver r = MockReceiver(payable(spoke.predictCrossAccount(transmitter, bytes32(0), spoke.homeChainKey())));
        assertEq(r.sourceTransmitter(), carried, "not a derivation: the address the hub vouched for");
    }

    /// @dev A payload the mock receiver will record. Its contents do not matter to the
    ///      transceiver, which never inspects one.
    function _boot() internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({target: address(0xDEAD), value: 0, data: hex"00"});
    }
}
