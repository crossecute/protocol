// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SpokeTransceiverBase} from "src/messaging/transceiver/SpokeTransceiverBase.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {ChainType} from "src/addressing/ChainType.sol";
import {Provenance} from "src/registry/ForeignRef.sol";
import {LzCodec} from "src/protocols/layerzero/LzCodec.sol";
import {LzHubTransceiver} from "src/protocols/layerzero/LzHubTransceiver.sol";
import {LzReceiver} from "src/protocols/layerzero/LzReceiver.sol";
import {LzSpokeTransceiver} from "src/protocols/layerzero/LzSpokeTransceiver.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRoutes} from "src/registry/IChainRegistryRoutes.sol";
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

    uint32 constant BASE_EID = 30184;
    uint32 constant ARB_EID = 30110;

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
                        (msig, recvImpl, abi.encodePacked(address(hub)))
                    )
                )
            )
        );

        vm.startPrank(msig);
        provider = registry.addMessageProvider("layerzero");
        hub.setRouting(
            IChainRegistryRoutes(address(registry)), provider, Provenance.Derived
        );
        vm.stopPrank();
    }

    /* ============================ the chainKey itself =========================== */

    /// @dev THE POINT OF THE WHOLE DESIGN. Both ends of a message derive the same key
    ///      from values they already have — a chain id in the signed payload on one side,
    ///      `block.chainid` on the other — so neither stores a chainKey anywhere.
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

    /// @dev THE LOAD-BEARING LITERAL. `HOME_CHAIN_KEY` is hardcoded rather than computed
    ///      so the spoke's initcode is byte-identical on every chain — CREATE2 parity
    ///      depends on that. This is the check that keeps the literal honest; if it ever
    ///      fails, every spoke is pointed at a chain that does not exist.
    function test_homeChainKeyMatchesEthereum() public view {
        assertEq(spoke.HOME_CHAIN_KEY(), ChainKey.forEvm(1));
    }

    /* =========================== provider route table ========================== */

    function _wireBase() internal returns (bytes32 baseKey) {
        vm.startPrank(msig);
        baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        bytes32 id = keccak256("lz.base");
        registry.resolveEvmCreate2(id, 8453, address(0x4e59), bytes32(0), bytes32(0));
        registry.setTransceiverId(baseKey, provider, id);
        registry.setProviderRoute(baseKey, provider, LzCodec.encodeEid(BASE_EID));
        vm.stopPrank();
    }

    /// @dev The translation the transmitter never has to know about: it names Base as
    ///      `8453`, and the eid appears for the first time inside the transceiver.
    function test_chainKeyResolvesToTheProvidersOwnId() public {
        bytes32 baseKey = _wireBase();
        assertEq(hub.eidFor(baseKey), BASE_EID);
        assertEq(hub.chainKeyForEid(BASE_EID), baseKey, "and back again, for inbound");
    }

    /// @dev Two chains sharing one eid would let an inbound message be attributed to the
    ///      wrong source chain. That is a forgery primitive, so it reverts.
    function test_oneEidCannotNameTwoChains() public {
        bytes32 baseKey = _wireBase();
        vm.startPrank(msig);
        bytes32 arbKey = registry.addChainKey(Erc7930.encodeEvmChain(42161));
        vm.expectRevert(ChainRegistry.RouteInUse.selector);
        registry.setProviderRoute(arbKey, provider, LzCodec.encodeEid(BASE_EID));
        vm.stopPrank();
        assertEq(registry.chainKeyOfRoute(provider, LzCodec.encodeEid(BASE_EID)), baseKey);
    }

    /// @dev Repointing a chain to a new eid must clear the old reverse entry, or the
    ///      stale one keeps resolving and the new one collides with itself.
    function test_repointingAnEidClearsTheOldReverseEntry() public {
        bytes32 baseKey = _wireBase();
        vm.prank(msig);
        registry.setProviderRoute(baseKey, provider, LzCodec.encodeEid(ARB_EID));

        assertEq(hub.eidFor(baseKey), ARB_EID);
        vm.expectRevert(ChainRegistry.NoProviderRoute.selector);
        registry.chainKeyOfRoute(provider, LzCodec.encodeEid(BASE_EID));
    }

    /// @dev Setting the same route twice is a no-op, not a self-collision.
    function test_rewritingTheSameRouteIsIdempotent() public {
        bytes32 baseKey = _wireBase();
        vm.prank(msig);
        registry.setProviderRoute(baseKey, provider, LzCodec.encodeEid(BASE_EID));
        assertEq(hub.eidFor(baseKey), BASE_EID);
    }

    /// @dev An unset route reverts rather than reading as eid 0, which is a real
    ///      LayerZero-adjacent value and would send into the void.
    function test_unsetRouteRevertsRatherThanReadingAsZero() public {
        vm.startPrank(msig);
        bytes32 key = registry.addChainKey(Erc7930.encodeEvmChain(10));
        vm.stopPrank();
        vm.expectRevert(ChainRegistry.NoProviderRoute.selector);
        hub.eidFor(key);
    }

    /// @dev A live provider route is a claim on the chain just as a transceiver id is.
    function test_chainKeyWithALiveRouteCannotBeRemoved() public {
        vm.startPrank(msig);
        bytes32 key = registry.addChainKey(Erc7930.encodeEvmChain(10));
        registry.setProviderRoute(key, provider, LzCodec.encodeEid(30111));

        vm.expectRevert(ChainRegistry.ChainKeyInUse.selector);
        registry.removeChainKey(key);

        registry.setProviderRoute(key, provider, "");
        registry.removeChainKey(key);
        vm.stopPrank();
        assertFalse(registry.hasChainKey(key));
    }

    /// @dev The counterpart and the eid are configured separately and must be readable
    ///      separately — otherwise a half-wired chain cannot be diagnosed.
    function test_counterpartIsReadableWithoutAnEid() public {
        vm.startPrank(msig);
        bytes32 key = registry.addChainKey(Erc7930.encodeEvmChain(10));
        bytes32 id = keccak256("lz.op");
        registry.resolveEvmCreate2(id, 10, address(0x4e59), bytes32(0), bytes32(0));
        registry.setTransceiverId(key, provider, id);
        vm.stopPrank();

        assertEq(hub.counterpartOn(key).length, 20, "counterpart resolves");
        vm.expectRevert(ChainRegistry.NoProviderRoute.selector);
        hub.routeTo(key);
    }

    function test_setProviderRouteIsOwnerGated() public {
        bytes32 baseKey = _wireBase();
        vm.expectRevert();
        registry.setProviderRoute(baseKey, provider, LzCodec.encodeEid(ARB_EID));
    }

    function test_providerRouteRequiresARegisteredChainAndProvider() public {
        vm.startPrank(msig);
        vm.expectRevert(ChainRegistry.UnknownChainKey.selector);
        registry.setProviderRoute(keccak256("nope"), provider, LzCodec.encodeEid(1));

        bytes32 key = registry.addChainKey(Erc7930.encodeEvmChain(10));
        vm.expectRevert(ChainRegistry.UnknownMessageProvider.selector);
        registry.setProviderRoute(key, keccak256("wormhole"), LzCodec.encodeEid(1));
        vm.stopPrank();
    }

    /* ================================ the spoke ================================ */

    /// @dev The spoke's whole routing layer. No registry, no lookup — the one destination
    ///      it has is a literal, and everything else is refused.
    function test_spokeRoutesHomeAndNowhereElse() public {
        bytes memory hubAddr = abi.encodePacked(address(hub));
        assertEq(spoke.counterpartOn(spoke.HOME_CHAIN_KEY()), hubAddr);
        assertEq(spoke.homeEid(), LzCodec.ETHEREUM_EID);
        assertEq(LzCodec.decodeEid(spoke.routeTo(spoke.HOME_CHAIN_KEY())), 30101);

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
        spoke.initialize(msig, address(0xBEEF), abi.encodePacked(address(0xBAD)));
        assertEq(spoke.homeTransceiver(), abi.encodePacked(address(hub)), "unchanged");
    }

    /// @dev A spoke with no counterpart is not a half-configured spoke, it is one that
    ///      should never have been deployed — so it fails at initialization.
    function test_homeTransceiverIsRequiredAtInitialization() public {
        LzSpokeTransceiver impl = new LzSpokeTransceiver();
        vm.expectRevert(SpokeTransceiverBase.NoHomeTransceiver.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                LzSpokeTransceiver.initialize, (msig, address(0xBEEF), bytes(""))
            )
        );
    }



    /* ================================= codec =================================== */

    /// @dev Fixed-width encoding, so a value configured at the wrong width fails in
    ///      `decode` rather than being silently reinterpreted as another chain.
    function test_routeIsFixedWidthSoMistypedConfigFails() public {
        vm.startPrank(msig);
        bytes32 key = registry.addChainKey(Erc7930.encodeEvmChain(10));
        registry.setProviderRoute(key, provider, abi.encodePacked(uint32(30111)));
        vm.stopPrank();

        assertEq(LzCodec.encodeEid(30111).length, 32, "abi.encode pads to a word");
        vm.expectRevert();
        hub.eidFor(key);
    }

    function testFuzz_eidRoundTrips(uint32 eid) public pure {
        assertEq(LzCodec.decodeEid(LzCodec.encodeEid(eid)), eid);
    }
}
