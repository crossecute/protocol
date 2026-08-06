// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Envelope} from "src/messaging/Envelope.sol";
import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {SpokeTransceiverBase} from "src/messaging/transceiver/SpokeTransceiverBase.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {ChainType} from "src/addressing/ChainType.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Provenance} from "src/registry/ForeignRef.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRoutes} from "src/registry/IChainRegistryRoutes.sol";

contract MockReceiver is ReceiverBase {
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
contract Hub is HubTransceiverBase, OwnableUpgradeable {
    function initialize(address owner_, address impl) external initializer {
        __Ownable_init(owner_);
        __TransceiverBase_init();
    }

    function _checkAdmin() internal view override {
        _checkOwner();
    }

    function arrive(bytes memory route, bytes memory sender, bytes calldata message)
        external
    {
        _onInbound(route, sender, message);
    }
}

contract Spoke is SpokeTransceiverBase, OwnableUpgradeable {
    function initialize(address owner_, address impl, bytes calldata home)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransceiverBase_init();
        __SpokeTransceiverBase_init(impl, home);
    }

    function _checkAdmin() internal view override {
        _checkOwner();
    }

    function _homeRoute() internal pure override returns (bytes memory) {
        return abi.encode(uint32(30101));
    }

    function arrive(bytes memory route, bytes memory sender, bytes calldata message)
        external
    {
        _onInbound(route, sender, message);
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
    bytes constant HOME_ROUTE = abi.encode(uint32(30101));

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
        hub.initialize(msig, impl);
        spoke = new Spoke();
        spoke.initialize(msig, impl, HOME_SENDER);

        vm.startPrank(msig);
        provider = registry.addMessageProvider("layerzero");
        hub.setRouting(
            IChainRegistryRoutes(address(registry)), provider, Provenance.Attested
        );
        registry.setLocalTransceiver(provider, address(hub));
        vm.stopPrank();
    }

    /* ================================== spoke ================================== */

    /// @dev ONE ORIGIN, SO IT IS A COMPARISON. No registry, no lookup that could return
    ///      the wrong answer if configuration drifted.
    function test_spokeAcceptsTheHubAndStandsTheReceiverUp() public {
        spoke.arrive(HOME_ROUTE, HOME_SENDER, Envelope.encodeBootstrap(transmitter, _boot()));

        MockReceiver r = MockReceiver(payable(spoke.predictXSafeAccount(transmitter)));
        assertEq(r.sourceTransmitter(), address(r), "its peer is its own address across chains");
        assertEq(r.executedCount(), 1, "and its payload ran on arrival");
    }

    /// @dev A sibling spoke sending from a chain the hub also talks to is still not the
    ///      hub. Both halves of the check are load-bearing.
    function test_spokeRejectsTheRightRouteFromTheWrongSender() public {
        bytes memory msg_ = Envelope.encodeBootstrap(transmitter, _boot());
        vm.expectRevert(SpokeTransceiverBase.NotHomeOrigin.selector);
        spoke.arrive(HOME_ROUTE, abi.encodePacked(address(0xBAD)), msg_);
    }

    function test_spokeRejectsTheRightSenderFromTheWrongRoute() public {
        bytes memory msg_ = Envelope.encodeBootstrap(transmitter, _boot());
        vm.expectRevert(SpokeTransceiverBase.NotHomeOrigin.selector);
        spoke.arrive(abi.encode(uint32(30184)), HOME_SENDER, msg_);
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

    function _wireSpokeChain(uint32 eid, uint256 chainId, address counterpart)
        internal
        returns (bytes32 chainKey)
    {
        vm.startPrank(msig);
        chainKey = registry.addChainKey(Erc7930.encodeEvmChain(chainId));
        bytes32 id = keccak256(abi.encode("t", chainId));
        registry.resolveDerived(id, Erc7930.encodeEvm(chainId, counterpart));
        registry.setTransceiverId(chainKey, provider, id);
        registry.setProviderRoute(chainKey, provider, abi.encode(eid));
        vm.stopPrank();
    }

    /// @dev N ORIGINS, SO IT IS A LOOKUP. The route names the chain and the registry names
    ///      that chain's counterpart; the report is recorded against the chain the route
    ///      resolved to, not one the message claimed.
    function test_hubResolvesTheOriginAndRecordsTheReport() public {
        address counterpart = address(0xC0DE);
        bytes32 baseKey = _wireSpokeChain(30184, 8453, counterpart);

        bytes memory interop = Erc7930.encodeEvm(8453, address(0xBEEF));
        hub.arrive(
            abi.encode(uint32(30184)),
            abi.encodePacked(counterpart),
            Envelope.encodeReceiverReport(transmitter, interop)
        );

        assertEq(
            hub.destinationReceiverOn(baseKey, transmitter),
            abi.encodePacked(address(0xBEEF)),
            "recorded against the chain the ROUTE resolved to"
        );
    }

    function test_hubRejectsAnUnknownRoute() public {
        bytes memory m =
            Envelope.encodeReceiverReport(transmitter, bytes(""));
        vm.expectRevert(ChainRegistry.NoProviderRoute.selector);
        hub.arrive(abi.encode(uint32(99999)), abi.encodePacked(address(0xC0DE)), m);
    }

    /// @dev A known chain speaking with the wrong contract is refused. Without this, any
    ///      contract on a registered chain could report receiver addresses.
    function test_hubRejectsAKnownRouteFromTheWrongSender() public {
        bytes32 baseKey = _wireSpokeChain(30184, 8453, address(0xC0DE));
        bytes memory m =
            Envelope.encodeReceiverReport(transmitter, bytes(""));

        vm.expectRevert(
            abi.encodeWithSelector(HubTransceiverBase.NotCounterpart.selector, baseKey)
        );
        hub.arrive(abi.encode(uint32(30184)), abi.encodePacked(address(0xBAD)), m);
    }

    /// @dev The provenance bar gates the inbound path too. A chain whose counterpart is
    ///      only `Attested` cannot drive a hub that demands `Derived`, however well-formed
    ///      its message is.
    function test_hubProvenanceBarAppliesToInbound() public {
        address counterpart = address(0xC0DE);
        vm.startPrank(msig);
        bytes32 chainKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        registry.setProviderRoute(chainKey, provider, abi.encode(uint32(30184)));
        vm.stopPrank();

        // Learned from the destination, so `Attested` — the weakest grade there is.
        vm.prank(address(hub));
        registry.onForeignRefResolved(
            keccak256("lz.base"), Erc7930.encodeEvm(8453, counterpart), ""
        );
        vm.prank(msig);
        registry.setTransceiverId(chainKey, provider, keccak256("lz.base"));

        // At the weakest bar the message is accepted.
        bytes memory report = Envelope.encodeReceiverReport(
            transmitter, Erc7930.encodeEvm(8453, address(0xBEEF))
        );
        hub.arrive(abi.encode(uint32(30184)), abi.encodePacked(counterpart), report);

        // Raise it, and the same well-formed message from the same contract is refused.
        vm.prank(msig);
        hub.setRouting(
            IChainRegistryRoutes(address(registry)), provider, Provenance.Derived
        );
        bytes memory report2 = Envelope.encodeReceiverReport(
            transmitter, Erc7930.encodeEvm(8453, address(0xBEEF))
        );
        vm.expectRevert(ChainRegistry.InsufficientProvenance.selector);
        hub.arrive(abi.encode(uint32(30184)), abi.encodePacked(counterpart), report2);
    }

    /* ================================= envelope ================================ */

    /// @dev Each side decodes exactly one shape, so the direction is the discriminant and
    ///      no type tag is needed. Feeding a hub a spoke's message is a decode failure,
    ///      not a misread.
    function test_theWrongShapeDoesNotDecodeSilently() public {
        _wireSpokeChain(30184, 8453, address(0xC0DE));
        bytes memory wrongWay = Envelope.encodeBootstrap(transmitter, _boot());

        vm.expectRevert();
        hub.arrive(abi.encode(uint32(30184)), abi.encodePacked(address(0xC0DE)), wrongWay);
    }

    function testFuzz_bootstrapEnvelopeRoundTrips(address t_, address target, bytes memory data)
        public
        view
    {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: target, value: 3, data: data});

        (address gotT, Call[] memory got) =
            this.peekBootstrap(Envelope.encodeBootstrap(t_, calls));

        assertEq(gotT, t_);
        assertEq(got.length, 1);
        assertEq(got[0].target, target);
        assertEq(got[0].value, 3);
        assertEq(got[0].data, data);
    }

    function peekBootstrap(bytes calldata m)
        external
        pure
        returns (address, Call[] memory)
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
