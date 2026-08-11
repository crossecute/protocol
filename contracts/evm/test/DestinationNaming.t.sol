// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SpokeTransceiverBase} from "src/messaging/transceiver/SpokeTransceiverBase.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {ChainType} from "src/addressing/ChainType.sol";
import {Provenance} from "src/registry/ForeignRef.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {LzHubTransceiver} from "src/protocols/layerzero/LzHubTransceiver.sol";
import {LzReceiver} from "src/protocols/layerzero/LzReceiver.sol";
import {LzSpokeTransceiver} from "src/protocols/layerzero/LzSpokeTransceiver.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice How a destination is named end to end: a plain chain id at the transmitter,
///         a chainKey across the protocol, and the provider's own id only at the edge.
contract MockTransmitterImpl {
    function initialize(address, address) external {}
}

contract DestinationNamingTest is Test {
    ChainRegistry registry;
    LzHubTransceiver hub;
    LzSpokeTransceiver spoke;

    address msig = address(0x5165);
    bytes32 provider;

    /// @dev The route slot holds a chain's ERC-7930 identifier now, not a provider's id
    ///      for it: an ERC-7786 recipient names its own chain, so there is nothing left to
    ///      translate. `keccak256(BASE_ROUTE)` IS `baseKey`, by definition.
    bytes BASE_ROUTE = Erc7930.encodeEvmChain(8453);
    bytes ARB_ROUTE = Erc7930.encodeEvmChain(42161);

    function setUp() public {
        registry = ChainRegistry(
            address(
                new ERC1967Proxy(
                    address(new ChainRegistry()),
                    abi.encodeCall(ChainRegistry.initialize, (msig))
                )
            )
        );
        address recvImpl = address(new LzReceiver());
        hub = LzHubTransceiver(
            address(
                new ERC1967Proxy(
                    address(new LzHubTransceiver()),
                    abi.encodeCall(LzHubTransceiver.initialize, (msig, address(new MockTransmitterImpl())))
                )
            )
        );
        // The hub address is knowable before the spoke is initialized, which is what lets
        // the counterpart be an initializer argument rather than a setter.
        spoke = LzSpokeTransceiver(
            address(
                new ERC1967Proxy(
                    address(new LzSpokeTransceiver()),
                    abi.encodeCall(
                        LzSpokeTransceiver.initialize,
                        (
                            msig,
                            recvImpl,
                            ChainKey.forEvm(1),
                            Erc7930.encodeEvmChain(1),
                            abi.encodePacked(address(hub)),
                            false
                        )
                    )
                )
            )
        );

        vm.startPrank(msig);
        provider = registry.addMessageProvider("layerzero");
        hub.setRouting(
            IChainRegistryRefs(address(registry)), provider, Provenance.Derived
        );
        vm.stopPrank();
    }

    /* ============================ the chainKey itself =========================== */

    /// @dev THE POINT OF THE WHOLE DESIGN. Both ends of a message derive the same key
    ///      from values they already have (a chain id in the signed payload on one side,
    ///      `block.chainid` on the other), so neither stores a chainKey anywhere.
    function test_chainKeyNeedsNoStorageOnEitherSide() public {
        vm.chainId(8453);
        assertEq(ChainKey.local(), ChainKey.forEvm(8453), "destination derives its own");
        assertEq(
            ChainKey.forEvm(8453),
            ChainKey.fromIdentifier(Erc7930.encodeEvmChain(8453)),
            "and it is the same key the registry indexes by"
        );
    }

    /// @dev An account envelope reduces to its chain, so every address on a chain yields
    ///      one key and `submitTo` accepts either form.
    function test_chainKeyIsStableAcrossAddressesOnAChain() public pure {
        bytes memory acct = Erc7930.encodeEvm(8453, address(0xBEEF));
        assertEq(ChainKey.fromIdentifier(acct), ChainKey.forEvm(8453));
    }

    /// @dev THE LOAD-BEARING LITERAL. `homeChainKey` is hardcoded rather than computed
    ///      so the spoke's initcode is byte-identical on every chain: CREATE2 parity
    ///      depends on that. This is the check that keeps the literal honest; if it ever
    ///      fails, every spoke is pointed at a chain that does not exist.
    /// @dev THIS deployment anchors on Ethereum, which is a fact about the initializer
    ///      arguments above and not about the protocol. See the next test.
    function test_thisDeploymentIsAnchoredOnEthereum() public view {
        assertEq(spoke.homeChainKey(), ChainKey.forEvm(1));
        assertEq(spoke.homeRoute(), Erc7930.encodeEvmChain(1));
    }

    /// @dev THE HOME CHAIN IS A PARAMETER, NOT ETHEREUM. Ethereum is the expected anchor,
    ///      but nothing in the protocol requires it: a team can centralize on whichever
    ///      chain they are willing to anchor to, and every spoke simply names that one
    ///      instead. The spoke is exactly as rigid either way (three write-once values,
    ///      no setters), so the choice costs nothing in guarantees.
    function test_aTeamCanAnchorOnADifferentChain() public {
        address arbHub = address(0xA4B);
        LzSpokeTransceiver arbSpoke = LzSpokeTransceiver(
            address(
                new ERC1967Proxy(
                    address(new LzSpokeTransceiver()),
                    abi.encodeCall(
                        LzSpokeTransceiver.initialize,
                        (
                            msig,
                            address(new LzReceiver()),
                            ChainKey.forEvm(42161),
                            Erc7930.encodeEvmChain(42161),
                            abi.encodePacked(arbHub),
                            false
                        )
                    )
                )
            )
        );

        assertEq(arbSpoke.homeChainKey(), ChainKey.forEvm(42161), "Arbitrum is home");
        assertEq(arbSpoke.homeRoute(), Erc7930.encodeEvmChain(42161));
        assertEq(arbSpoke.homeTransceiver(), abi.encodePacked(arbHub));
        assertEq(arbSpoke.counterpartOn(ChainKey.forEvm(42161)), abi.encodePacked(arbHub));

        // And Ethereum is now just another chain it refuses to talk to.
        vm.expectRevert(
            abi.encodeWithSelector(SpokeTransceiverBase.NotHome.selector, ChainKey.forEvm(1))
        );
        arbSpoke.counterpartOn(ChainKey.forEvm(1));
    }

    /// @dev The home values are write-once with no setters, whichever chain they name.
    function test_theHomeCannotBeRepointedOnAnyChain() public {
        (bool a,) = address(spoke).call(
            abi.encodeWithSignature("setHomeChainKey(bytes32)", bytes32(uint256(1)))
        );
        assertFalse(a, "no setHomeChainKey");

        (bool b,) = address(spoke).call(
            abi.encodeWithSignature("setHomeRoute(bytes)", Erc7930.encodeEvmChain(1))
        );
        assertFalse(b, "no setHomeRoute");
    }

    /* =========================== provider route table ========================== */

    function _wireBase() internal returns (bytes32 baseKey) {
        vm.startPrank(msig);
        baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        bytes32 id = keccak256("lz.base");
        registry.resolveEvmCreate2(id, 8453, address(0x4e59), bytes32(0), bytes32(0));
        registry.setTransceiverId(baseKey, provider, id);
        hub.setRoute(baseKey, BASE_ROUTE);
        vm.stopPrank();
    }

    /// @dev The translation the transmitter never has to know about: it names Base as
    ///      `8453`, and the eid appears for the first time inside the transceiver.
    function test_chainKeyResolvesToTheProvidersOwnId() public {
        bytes32 baseKey = _wireBase();
        assertEq(hub.routeTo(baseKey), BASE_ROUTE);
        assertEq(hub.chainKeyOfRoute(BASE_ROUTE), baseKey, "and back again, for inbound");
    }

    /// @dev Two chains sharing one eid would let an inbound message be attributed to the
    ///      wrong source chain. That is a forgery primitive, so it reverts.
    function test_oneEidCannotNameTwoChains() public {
        bytes32 baseKey = _wireBase();
        vm.startPrank(msig);
        bytes32 arbKey = registry.addChainKey(Erc7930.encodeEvmChain(42161));
        vm.expectRevert(
            abi.encodeWithSelector(
                OutboundBase.RouteInUse.selector, keccak256(BASE_ROUTE)
            )
        );
        hub.setRoute(arbKey, BASE_ROUTE);
        vm.stopPrank();
        assertEq(hub.chainKeyOfRoute(BASE_ROUTE), baseKey);
    }

    /// @dev Setting the same route twice is a no-op, not a self-collision.
    function test_rewritingTheSameRouteIsIdempotent() public {
        bytes32 baseKey = _wireBase();
        vm.prank(msig);
        hub.setRoute(baseKey, BASE_ROUTE);
        assertEq(hub.routeTo(baseKey), BASE_ROUTE);
    }

    /// @dev An unset route reverts rather than reading as eid 0, which is a real
    ///      LayerZero-adjacent value and would send into the void.
    function test_unsetRouteRevertsRatherThanReadingAsZero() public {
        vm.startPrank(msig);
        bytes32 key = registry.addChainKey(Erc7930.encodeEvmChain(10));
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(OutboundBase.NoRouteFor.selector, key)
        );
        hub.routeTo(key);
    }

    /// @dev A live transceiver id is a claim on the chain, so the directory refuses to
    ///      drop it out from under one. Routes are no longer the registry's business, so
    ///      they are not part of this check: they live on the transceiver.
    function test_chainKeyWithALiveTransceiverCannotBeRemoved() public {
        vm.startPrank(msig);
        bytes32 key = registry.addChainKey(Erc7930.encodeEvmChain(10));
        registry.setTransceiverId(key, provider, keccak256("lz.op"));

        vm.expectRevert(ChainRegistry.ChainKeyInUse.selector);
        registry.removeChainKey(key);
        vm.stopPrank();

        assertTrue(registry.hasChainKey(key));
    }

    /// @dev The counterpart and the eid are configured separately and must be readable
    ///      separately: otherwise a half-wired chain cannot be diagnosed.
    function test_counterpartIsReadableWithoutAnEid() public {
        vm.startPrank(msig);
        bytes32 key = registry.addChainKey(Erc7930.encodeEvmChain(10));
        bytes32 id = keccak256("lz.op");
        registry.resolveEvmCreate2(id, 10, address(0x4e59), bytes32(0), bytes32(0));
        registry.setTransceiverId(key, provider, id);
        vm.stopPrank();

        assertEq(hub.counterpartOn(key).length, 20, "counterpart resolves");
        vm.expectRevert(
            abi.encodeWithSelector(OutboundBase.NoRouteFor.selector, key)
        );
        hub.routeTo(key);
    }

    function test_setProviderRouteIsOwnerGated() public {
        bytes32 baseKey = _wireBase();
        vm.expectRevert();
        hub.setRoute(baseKey, ARB_ROUTE);
    }

    /// @dev A route is WRITE-ONCE. Re-pointing one would redirect every message to that
    ///      destination at once, which is a redeploy rather than a config edit.
    function test_aRouteCannotBeRepointed() public {
        bytes32 baseKey = _wireBase();

        vm.prank(msig);
        vm.expectRevert(
            abi.encodeWithSelector(OutboundBase.RouteAlreadySet.selector, baseKey)
        );
        hub.setRoute(baseKey, ARB_ROUTE);

        assertEq(hub.routeTo(baseKey), BASE_ROUTE, "unchanged");
    }

    /// @dev THE ROUTE LIVES WHERE THE SENDING HAPPENS. A registry read would put a second
    ///      shared contract in the path of every send, and a compromised one could
    ///      misroute a payload, which on the execute-on-arrival path means it runs on the
    ///      wrong chain, with no commitment binding the destination.
    function test_theRegistryHoldsNoRoutes() public {
        (bool a,) = address(registry).call(
            abi.encodeWithSignature(
                "setProviderRoute(bytes32,bytes32,bytes)", bytes32(0), bytes32(0), ""
            )
        );
        assertFalse(a, "no setProviderRoute");

        (bool b,) = address(registry).staticcall(
            abi.encodeWithSignature("providerRoute(bytes32,bytes32)", bytes32(0), bytes32(0))
        );
        assertFalse(b, "and no reader for one");
    }

    /* ================================ the spoke ================================ */

    /// @dev The spoke's whole routing layer. No registry, no lookup: the one destination
    ///      it has is a literal, and everything else is refused.
    function test_spokeRoutesHomeAndNowhereElse() public {
        bytes memory hubAddr = abi.encodePacked(address(hub));
        assertEq(spoke.counterpartOn(spoke.homeChainKey()), hubAddr);
        assertEq(spoke.homeRoute(), Erc7930.encodeEvmChain(1));
        assertEq(spoke.routeTo(spoke.homeChainKey()), Erc7930.encodeEvmChain(1));

        bytes32 baseKey = ChainKey.forEvm(8453);
        vm.expectRevert(
            abi.encodeWithSelector(SpokeTransceiverBase.NotHome.selector, baseKey)
        );
        spoke.counterpartOn(baseKey);
    }

    /// @dev A spoke cannot be configured into talking to another spoke. Nothing to set,
    ///      so nothing to compromise.
    function test_spokeHasNoSetterForASecondDestination() public {
        bytes32 solKey = ChainKey.fromIdentifier(
            Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708")
        );
        vm.expectRevert(
            abi.encodeWithSelector(SpokeTransceiverBase.NotHome.selector, solKey)
        );
        spoke.routeTo(solKey);
    }

    /// @dev THERE IS NO WINDOW, NOT MERELY A CLOSABLE ONE. A setter plus a lock would
    ///      leave a period in which the admin could repoint the one address the spoke
    ///      authenticates every inbound message against. The counterpart is an initializer
    ///      argument with no setter, so there is no reachable state in which it is set and
    ///      still changeable.
    function test_homeTransceiverHasNoSetterAtAll() public {
        assertEq(spoke.homeTransceiver(), abi.encodePacked(address(hub)));

        (bool a,) = address(spoke).call(
            abi.encodeWithSignature(
                "setHomeTransceiver(bytes)", abi.encodePacked(address(0xBAD))
            )
        );
        assertFalse(a, "no setter on the ABI");
        (bool b,) = address(spoke).call(abi.encodeWithSignature("lockHome()"));
        assertFalse(b, "and nothing to lock");

        vm.prank(msig);
        vm.expectRevert();
        spoke.initialize(
            msig,
            address(0xBEEF),
            ChainKey.forEvm(1),
            Erc7930.encodeEvmChain(1),
            abi.encodePacked(address(0xBAD)),
            false
        );
        assertEq(spoke.homeTransceiver(), abi.encodePacked(address(hub)), "unchanged");
    }

    /// @dev A spoke with no counterpart is not a half-configured spoke, it is one that
    ///      should never have been deployed, so it fails at initialization.
    function test_homeTransceiverIsRequiredAtInitialization() public {
        LzSpokeTransceiver impl = new LzSpokeTransceiver();
        vm.expectRevert(SpokeTransceiverBase.NoHomeTransceiver.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                LzSpokeTransceiver.initialize,
                (
                    msig,
                    address(0xBEEF),
                    ChainKey.forEvm(1),
                    Erc7930.encodeEvmChain(1),
                    bytes(""),
                    false
                )
            )
        );
    }



    /* ================================= codec =================================== */

    /// @dev Fixed-width encoding, so a value configured at the wrong width fails in
    ///      `decode` rather than being silently reinterpreted as another chain.
    /// @dev A ROUTE THAT IS NOT A CANONICAL CHAIN IDENTIFIER CANNOT BE USED. The old test
    ///      here checked that a mistyped endpoint id failed in `abi.decode`; there is no
    ///      endpoint id any more, and the equivalent mistake is a route that does not parse
    ///      as ERC-7930. It is caught when a recipient is built from it rather than at
    ///      `setRoute`, which stores opaque bytes by design.
    function test_aRouteThatIsNotAChainIdentifierFailsWhenUsed() public {
        vm.startPrank(msig);
        bytes32 key = registry.addChainKey(Erc7930.encodeEvmChain(10));
        hub.setRoute(key, abi.encodePacked(uint32(30111)));
        vm.stopPrank();

        // Stored happily, because the base has no opinion about what a route contains.
        assertEq(hub.routeTo(key), abi.encodePacked(uint32(30111)));

        // And refused the moment anything asks it to name a chain. The read happens
        // first, so `expectRevert` lands on the call under test rather than on it.
        bytes memory stored = hub.routeTo(key);
        vm.expectRevert();
        this.chainKeyOf(stored);
    }

    function chainKeyOf(bytes memory route) external pure returns (bytes32) {
        return ChainKey.fromIdentifier(route);
    }

    /// @dev `keccak256(identifier) == chainKey` is the DEFINITION of a chainKey, which is
    ///      what lets the route slot hold an identifier and the reverse index be correct
    ///      without being maintained.
    function testFuzz_aChainIdentifierRoundTripsToItsKey(uint256 chainId) public pure {
        vm.assume(chainId != 0);
        assertEq(
            ChainKey.fromIdentifier(Erc7930.encodeEvmChain(chainId)),
            ChainKey.forEvm(chainId)
        );
    }
}
