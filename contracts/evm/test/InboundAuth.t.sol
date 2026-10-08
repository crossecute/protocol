// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Test} from "forge-std/Test.sol";

import {Envelope} from "src/messaging/Envelope.sol";
import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {unseeded} from "test/RegistrySeed.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {UnsendableTransceiver, UnsendableTransmitter} from "test/Unsendable.sol";

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

/// @dev One transceiver, which is both ends: it creates receivers for accounts homed on an
///      origin it authenticates, and receives reports for accounts homed here.
contract Node is UnsendableTransceiver {
    function initialize(address governor, address transmitterImpl, address receiverImpl) external initializer {
        __TransceiverBase_init(
            TransceiverConfig({
                gateways: new address[](0),
                transmitterImplementation: transmitterImpl,
                receiverImplementation: receiverImpl,
                governorOwner: governor,
                governorSalt: bytes32(0),
                governorHome: Erc7930.encodeEvmChain(block.chainid),
                treasury: address(0x7EA5),
                chainRegistry: IChainRegistryRefs(address(0)),
                messageProvider: bytes32(0),
                minCounterpartProvenance: Provenance.Unknown
            })
        );
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

contract InboundAuthTest is Test {
    Node node;
    ChainRegistry registry;
    address owner;

    address msig = address(0x5165);
    address transmitter = address(0x7A11);
    bytes32 provider;

    /// Chain 1, a `Predetermined` origin whose transceiver shares this one's address. Set in
    /// `setUp`.
    bytes32 homeKey;
    bytes HOME_SENDER;
    bytes HOME_ROUTE = Erc7930.encodeEvmChain(1);

    function setUp() public {
        registry = new ChainRegistry(msig, unseeded());
        node = new Node();
        node.initialize(msig, address(new Transmitter()), address(new MockReceiver()));
        owner = node.owner();
        HOME_SENDER = abi.encodePacked(address(node));

        vm.startPrank(msig);
        provider = registry.addMessageProvider("layerzero");
        homeKey = registry.addChainKey(HOME_ROUTE, Provenance.Predetermined);
        registry.setLocalTransceiver(provider, address(node));
        vm.stopPrank();

        vm.startPrank(owner);
        node.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Unique);
        node.setRoute(homeKey, HOME_ROUTE);
        vm.stopPrank();
    }

    /* ============================ a bootstrap's origin ============================ */

    /// @dev The origin is a lookup: the route names the chain, and the chain names its
    ///      counterpart, here the default at this transceiver's own address.
    function test_aBootstrapFromTheCounterpartStandsTheReceiverUp() public {
        node.arrive(HOME_ROUTE, HOME_SENDER, _bootstrapMsg());

        MockReceiver r = MockReceiver(payable(node.predictCrossAccount(transmitter, bytes32(0), homeKey)));
        assertEq(r.sourceTransmitter(), address(uint160(uint256(_homeTransmitter()))), "its peer is the carried one");
        assertEq(r.executedCount(), 1, "and its payload ran on arrival");
    }

    /// @dev A sibling transceiver sending from a chain this one talks to is still not the
    ///      counterpart. Both halves of the check are load-bearing.
    function test_theRightRouteFromTheWrongSenderIsRefused() public {
        bytes memory msg_ = _bootstrapMsg();
        vm.expectRevert(abi.encodeWithSelector(TransceiverBase.NotCounterpart.selector, homeKey));
        node.arrive(HOME_ROUTE, abi.encodePacked(address(0xBAD)), msg_);
    }

    function test_theRightSenderFromTheWrongRouteIsRefused() public {
        bytes32 baseKey = _wireReportingChain(8453, address(0xC0DE));
        bytes memory msg_ = _bootstrapMsg();
        vm.expectRevert(abi.encodeWithSelector(TransceiverBase.NotCounterpart.selector, baseKey));
        node.arrive(Erc7930.encodeEvmChain(8453), HOME_SENDER, msg_);
    }

    /// @dev A receiver may call its transceiver, but only an account homed on this chain may
    ///      bootstrap from it, and a receiver here is homed elsewhere.
    function test_aReceiverCannotBootstrapFromHere() public {
        node.arrive(HOME_ROUTE, HOME_SENDER, _bootstrapMsg());
        address receiver = node.predictCrossAccount(transmitter, bytes32(0), homeKey);

        vm.deal(receiver, 1 ether);
        vm.prank(receiver);
        vm.expectRevert(
            abi.encodeWithSelector(TransceiverBase.NotTheAccount.selector, transmitter, bytes32(0), receiver)
        );
        node.bootstrap{value: 1 ether}(homeKey, transmitter, bytes32(0), _boot(), new bytes[](0));
    }

    /* ================================== reports ================================== */

    /// @dev A chain that reports is one this contract cannot derive an account on: `eip155`
    ///      graded below `Predetermined` is the zkSync and Tron shape.
    function _wireReportingChain(uint256 chainId, address counterpart) internal returns (bytes32 chainKey) {
        vm.startPrank(msig);
        chainKey = registry.addChainKey(Erc7930.encodeEvmChain(chainId), Provenance.Unique);
        vm.stopPrank();
        vm.startPrank(owner);
        node.setCounterpart(chainKey, Erc7930.encodeEvm(chainId, counterpart));
        node.setRoute(chainKey, Erc7930.encodeEvmChain(chainId));
        // A reporting destination refuses a free bootstrap.
        node.setBootstrapFee(chainKey, 1);
        vm.stopPrank();
    }

    /// @dev N origins, so it is a lookup. The route names the chain and the registry names
    ///      that chain's counterpart; the report is recorded against the chain the route
    ///      resolved to, not one the message claimed.
    function test_theOriginIsResolvedAndTheReportRecorded() public {
        address counterpart = address(0xC0DE);
        bytes32 baseKey = _wireReportingChain(8453, counterpart);
        Transmitter acct = _standUpAccount(8453);

        bytes memory interop = Erc7930.encodeEvm(8453, address(0xBEEF));
        node.arrive(
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
        acct = Transmitter(payable(node.createTransmitter(bytes32(0))));
        vm.deal(address(acct), 1 ether);
        acct.bootstrap(chainId, new Call[](0), new bytes[](0));
        vm.stopPrank();
    }

    function test_anUnknownRouteIsRefused() public {
        bytes memory m = Envelope.encodeReceiverReport(transmitter, bytes32(0), bytes(""));
        vm.expectRevert(OutboundBase.UnknownRoute.selector);
        node.arrive(abi.encode(uint32(99999)), abi.encodePacked(address(0xC0DE)), m);
    }

    /// @dev A known chain speaking with the wrong contract is refused. Without this, any
    ///      contract on a registered chain could report receiver addresses.
    function test_aKnownRouteFromTheWrongSenderIsRefused() public {
        bytes32 baseKey = _wireReportingChain(8453, address(0xC0DE));
        bytes memory m = Envelope.encodeReceiverReport(transmitter, bytes32(0), bytes(""));

        vm.expectRevert(abi.encodeWithSelector(TransceiverBase.NotCounterpart.selector, baseKey));
        node.arrive(Erc7930.encodeEvmChain(8453), abi.encodePacked(address(0xBAD)), m);
    }

    /// @dev The provenance bar gates the inbound path too. A chain whose counterpart is only
    ///      `Unique` cannot drive a transceiver that demands `Predetermined`, however well-formed
    ///      its message is.
    function test_theProvenanceBarAppliesToInbound() public {
        address counterpart = address(0xC0DE);
        // Graded `Unique`: the chain's addresses cannot be recomputed here, so any
        // claim about them is worth exactly the bridge that carried it.
        bytes32 chainKey = _wireReportingChain(8453, counterpart);
        _standUpAccount(8453);

        // At the weakest bar the message is accepted.
        bytes memory report =
            Envelope.encodeReceiverReport(transmitter, bytes32(0), Erc7930.encodeEvm(8453, address(0xBEEF)));
        node.arrive(Erc7930.encodeEvmChain(8453), abi.encodePacked(counterpart), report);

        // Raise it, and the same well-formed message from the same contract is refused.
        vm.prank(owner);
        node.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Predetermined);
        bytes memory report2 =
            Envelope.encodeReceiverReport(transmitter, bytes32(0), Erc7930.encodeEvm(8453, address(0xBEEF)));
        vm.expectRevert(
            abi.encodeWithSelector(
                TransceiverBase.InsufficientCounterpartProvenance.selector, chainKey, Provenance.Unique
            )
        );
        node.arrive(Erc7930.encodeEvmChain(8453), abi.encodePacked(counterpart), report2);
    }

    /// @dev Suspension cuts a chain off both ways: no report is accepted from it and no
    ///      bootstrap goes to it. Lifting it restores both, since it only ever refused.
    function test_aSuspendedChainIsRefusedBothWays() public {
        address counterpart = address(0xC0DE);
        bytes32 baseKey = _wireReportingChain(8453, counterpart);
        _standUpAccount(8453);
        bytes memory report =
            Envelope.encodeReceiverReport(transmitter, bytes32(0), Erc7930.encodeEvm(8453, address(0xBEEF)));

        vm.prank(msig);
        registry.setSuspended(baseKey, true);

        vm.expectRevert(abi.encodeWithSelector(TransceiverBase.ChainSuspended.selector, baseKey));
        node.arrive(Erc7930.encodeEvmChain(8453), abi.encodePacked(counterpart), report);

        address second = address(0x7A12);
        vm.startPrank(second);
        Transmitter acct = Transmitter(payable(node.createTransmitter(bytes32(0))));
        vm.expectRevert(abi.encodeWithSelector(TransceiverBase.ChainSuspended.selector, baseKey));
        acct.bootstrap(8453, new Call[](0), new bytes[](0));
        vm.stopPrank();

        vm.prank(msig);
        registry.setSuspended(baseKey, false);
        node.arrive(Erc7930.encodeEvmChain(8453), abi.encodePacked(counterpart), report);
        assertEq(
            Transmitter(payable(node.predictTransmitter(transmitter, bytes32(0)))).counterpartOn(baseKey).length, 20
        );
    }

    /* ================================= envelope ================================ */

    /// @dev Every envelope leads with its kind, so a wrong shape is refused by name rather
    ///      than misread. The elements form, which an EVM chain has no decoder for, is
    ///      `Transceiver.t.sol`'s.
    /// @dev A v1 body led with the owner, not a kind. Kinds start at 1, so the owner word is
    ///      refused as an unknown kind rather than decoded.
    function test_anUntaggedV1BodyIsRefused() public {
        bytes memory v1 = abi.encode(transmitter, bytes32(0), _boot());

        vm.expectRevert(abi.encodeWithSelector(Envelope.UnknownEnvelopeKind.selector, uint256(uint160(transmitter))));
        node.arrive(HOME_ROUTE, HOME_SENDER, v1);
    }

    /// @dev Shorter than the word that holds the kind.
    function test_aTruncatedEnvelopeIsRefused() public {
        bytes memory truncated = new bytes(31);
        truncated[30] = 0x01;

        vm.expectRevert(Envelope.EnvelopeTooShort.selector);
        node.arrive(HOME_ROUTE, HOME_SENDER, truncated);
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

    /// @dev The transmitter chain 1 would carry for `transmitter`'s account.
    function _homeTransmitter() internal view returns (bytes32) {
        return bytes32(uint256(uint160(node.predictCrossAccount(transmitter, bytes32(0), homeKey))));
    }

    function _bootstrapMsg() internal view returns (bytes memory) {
        return Envelope.encodeBootstrap(transmitter, bytes32(0), _homeTransmitter(), _boot());
    }

    /// @dev The transmitter is not derived here: the receiver answers to whatever address the
    ///      authenticated bootstrap carried. An EVM receiver can only answer to an EVM one.
    function test_aBootstrapMustCarryAnEvmTransmitter() public {
        bytes32 wide = bytes32(uint256(0xBEEF) << 160);
        bytes memory m = Envelope.encodeBootstrap(transmitter, bytes32(0), wide, _boot());

        vm.expectRevert(abi.encodeWithSelector(TransceiverBase.SourceTransmitterNotEvm.selector, wide));
        node.arrive(HOME_ROUTE, HOME_SENDER, m);
    }

    /// @dev A payload the mock receiver will record. Its contents do not matter to the
    ///      transceiver, which never inspects one.
    function _boot() internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({target: address(0xDEAD), value: 0, data: hex"00"});
    }
}
