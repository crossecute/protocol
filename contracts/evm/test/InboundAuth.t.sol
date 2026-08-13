// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Test} from "forge-std/Test.sol";

import {Deploy} from "test/Deployment.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Envelope} from "src/messaging/Envelope.sol";
import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {ChainType} from "src/addressing/ChainType.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";

contract MockReceiver is ReceiverBase {
    /// @dev A HARNESS TRUSTS ANY GATEWAY, which no deployment may do. Overriding the
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
contract Transmitter is TransmitterBase, OwnableUpgradeable {
    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    function _owner() internal view override returns (address) {
        return owner();
    }

    function _checkOwner() internal view override(TransmitterBase, OwnableUpgradeable) {
        OwnableUpgradeable._checkOwner();
    }

    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256)
        internal
        pure
        override
        returns (bytes32)
    {
        return bytes32(0);
    }

    /// @dev A HARNESS TRUSTS ANY GATEWAY, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }

}

contract Hub is HubTransceiverBase {
    function initialize(address owner_, address impl) external initializer {
        __HubTransceiverBase_init(Deploy.ownedBy(owner_), impl);
    }

    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256)
        internal
        pure
        override
        returns (bytes32)
    {
        return bytes32(0);
    }

    function arrive(bytes memory route, bytes memory sender, bytes calldata message)
        external
    {
        _onInbound(route, sender, message);
    }

    /// @dev A HARNESS TRUSTS ANY GATEWAY, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }

}

contract Spoke is SpokeTransceiverBase {
    function initialize(address owner_, address impl, bytes calldata home)
        external
        initializer
    {
        __SpokeTransceiverBase_init(
            Deploy.ownedBy(owner_),
            impl, ChainKey.forEvm(1), Erc7930.encodeEvmChain(1), home, false
        );
    }


    function arrive(bytes memory route, bytes memory sender, bytes calldata message)
        external
    {
        _onInbound(route, sender, message);
    }

    /// @dev A HARNESS TRUSTS ANY GATEWAY, which no deployment may do. Overriding the
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
            address(
                new ERC1967Proxy(
                    address(new ChainRegistry()),
                    abi.encodeCall(ChainRegistry.initialize, (msig))
                )
            )
        );
        address impl = address(new MockReceiver());
        hub = new Hub();
        hub.initialize(msig, address(new Transmitter()));
        spoke = new Spoke();
        spoke.initialize(msig, impl, HOME_SENDER);

        vm.startPrank(msig);
        provider = registry.addMessageProvider("layerzero");
        hub.setRouting(
            IChainRegistryRefs(address(registry)), provider, Provenance.Attested
        );
        registry.setLocalTransceiver(provider, address(hub));
        vm.stopPrank();
    }

    /* ================================== spoke ================================== */

    /// @dev ONE ORIGIN, SO IT IS A COMPARISON. No registry, no lookup that could return
    ///      the wrong answer if configuration drifted.
    function test_spokeAcceptsTheHubAndStandsTheReceiverUp() public {
        spoke.arrive(HOME_ROUTE, HOME_SENDER, Envelope.encodeBootstrap(transmitter, bytes32(0), _boot()));

        MockReceiver r = MockReceiver(payable(spoke.predictCrossAccount(transmitter, bytes32(0))));
        assertEq(r.sourceTransmitter(), address(r), "its peer is its own address across chains");
        assertEq(r.executedCount(), 1, "and its payload ran on arrival");
    }

    /// @dev A sibling spoke sending from a chain the hub also talks to is still not the
    ///      hub. Both halves of the check are load-bearing.
    function test_spokeRejectsTheRightRouteFromTheWrongSender() public {
        bytes memory msg_ = Envelope.encodeBootstrap(transmitter, bytes32(0), _boot());
        vm.expectRevert(SpokeTransceiverBase.NotHomeOrigin.selector);
        spoke.arrive(HOME_ROUTE, abi.encodePacked(address(0xBAD)), msg_);
    }

    function test_spokeRejectsTheRightSenderFromTheWrongRoute() public {
        bytes memory msg_ = Envelope.encodeBootstrap(transmitter, bytes32(0), _boot());
        vm.expectRevert(SpokeTransceiverBase.NotHomeOrigin.selector);
        spoke.arrive(Erc7930.encodeEvmChain(8453), HOME_SENDER, msg_);
    }

    /// @dev There is no setter by which a spoke could be made to accept a second origin.
    ///      The set of chains that can drive it is fixed at deployment.
    function test_spokeOriginCannotBeWidenedByAnyone() public {
        (bool a,) = address(spoke).call(
            abi.encodeWithSignature("setHomeTransceiver(bytes)", HOME_SENDER)
        );
        assertFalse(a);
        (bool b,) = address(spoke).call(
            abi.encodeWithSignature("setRouting(address,bytes32,uint8)", address(0), bytes32(0), 0)
        );
        assertFalse(b, "a spoke has no routing to set either");
    }

    /* =================================== hub =================================== */

    function _wireSpokeChain(uint32, uint256 chainId, address counterpart)
        internal
        returns (bytes32 chainKey)
    {
        vm.startPrank(msig);
        chainKey = registry.addChainKey(Erc7930.encodeEvmChain(chainId));
        // A chain that reports is one this contract cannot derive an account on: `eip155`
        // graded below `Derived` is the zkSync and Tron shape.
        registry.setProvenance(chainKey, Provenance.Attested);
        hub.setCounterpart(chainKey, Erc7930.encodeEvm(chainId, counterpart));
        vm.stopPrank();
        vm.prank(msig);
        // The route IS the chain identifier now, so `keccak256(route) == chainKey`.
        hub.setRoute(chainKey, Erc7930.encodeEvmChain(chainId));
        vm.startPrank(msig);
        vm.stopPrank();
    }

    /// @dev N ORIGINS, SO IT IS A LOOKUP. The route names the chain and the registry names
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
        bytes memory m =
            Envelope.encodeReceiverReport(transmitter, bytes32(0), bytes(""));
        vm.expectRevert(OutboundBase.UnknownRoute.selector);
        hub.arrive(abi.encode(uint32(99999)), abi.encodePacked(address(0xC0DE)), m);
    }

    /// @dev A known chain speaking with the wrong contract is refused. Without this, any
    ///      contract on a registered chain could report receiver addresses.
    function test_hubRejectsAKnownRouteFromTheWrongSender() public {
        bytes32 baseKey = _wireSpokeChain(30184, 8453, address(0xC0DE));
        bytes memory m =
            Envelope.encodeReceiverReport(transmitter, bytes32(0), bytes(""));

        vm.expectRevert(
            abi.encodeWithSelector(HubTransceiverBase.NotCounterpart.selector, baseKey)
        );
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
        bytes memory report = Envelope.encodeReceiverReport(
            transmitter, bytes32(0), Erc7930.encodeEvm(8453, address(0xBEEF))
        );
        hub.arrive(Erc7930.encodeEvmChain(8453), abi.encodePacked(counterpart), report);

        // Raise it, and the same well-formed message from the same contract is refused.
        vm.prank(msig);
        hub.setRouting(
            IChainRegistryRefs(address(registry)), provider, Provenance.Derived
        );
        bytes memory report2 = Envelope.encodeReceiverReport(
            transmitter, bytes32(0), Erc7930.encodeEvm(8453, address(0xBEEF))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                HubTransceiverBase.InsufficientCounterpartProvenance.selector,
                chainKey,
                Provenance.Attested
            )
        );
        hub.arrive(Erc7930.encodeEvmChain(8453), abi.encodePacked(counterpart), report2);
    }

    /* ================================= envelope ================================ */

    /// @dev Each side decodes exactly one shape, so the direction is the discriminant and
    ///      no type tag is needed. Feeding a hub a spoke's message is a decode failure,
    ///      not a misread.
    function test_theWrongShapeDoesNotDecodeSilently() public {
        _wireSpokeChain(30184, 8453, address(0xC0DE));
        bytes memory wrongWay = Envelope.encodeBootstrap(transmitter, bytes32(0), _boot());

        vm.expectRevert();
        hub.arrive(Erc7930.encodeEvmChain(8453), abi.encodePacked(address(0xC0DE)), wrongWay);
    }

    function testFuzz_bootstrapEnvelopeRoundTrips(address t_, address target, bytes memory data)
        public
        view
    {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: target, value: 3, data: data});

        (address gotT,, Call[] memory got) =
            this.peekBootstrap(Envelope.encodeBootstrap(t_, bytes32(0), calls));

        assertEq(gotT, t_);
        assertEq(got.length, 1);
        assertEq(got[0].target, target);
        assertEq(got[0].value, 3);
        assertEq(got[0].data, data);
    }

    function peekBootstrap(bytes calldata m)
        external
        pure
        returns (address, bytes32, Call[] memory)
    {
        return Envelope.decodeBootstrap(m);
    }

    /// @dev A payload the mock receiver will record. Its contents do not matter to the
    ///      transceiver, which never inspects one.
    function _boot() internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({target: address(0xDEAD), value: 0, data: hex"00"});
    }
}
