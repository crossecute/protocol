// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Test} from "forge-std/Test.sol";
import {deployTransceiver} from "test/DeployTransceiver.sol";

import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {LzTransceiver} from "src/protocols/layerzero/LzTransceiver.sol";
import {unseeded} from "test/RegistrySeed.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";
import {lzConfig} from "test/protocols/layerzero/LzTransceiver.t.sol";

/// @notice How a destination is named end to end: a plain chain id at the transmitter,
///         a chainKey across the protocol, and the provider's own id only at the edge.
contract DestinationNamingTest is Test {
    ChainRegistry registry;
    LzTransceiver t;

    /// The transceiver's owner, the msig's account here.
    address msig;
    bytes32 provider;

    address ENDPOINT = address(new MockLzEndpoint());

    /// @dev The route slot holds a chain's ERC-7930 identifier now, not a provider's id
    ///      for it: an ERC-7786 recipient names its own chain, so there is nothing left to
    ///      translate. `keccak256(BASE_ROUTE)` is `baseKey`, by definition.
    bytes BASE_ROUTE = Erc7930.encodeEvmChain(8453);
    bytes ARB_ROUTE = Erc7930.encodeEvmChain(42161);

    /// @dev One caller configures both the registry and the transceiver here, so each test
    ///      reads as one configuration step. Production owners differ (a timelock and the
    ///      msig's account); nothing below depends on which one holds which.
    function setUp() public {
        t = LzTransceiver(
            payable(address(
                    deployTransceiver(
                        address(new LzTransceiver(ENDPOINT)),
                        abi.encodeCall(LzTransceiver.initialize, (lzConfig(ENDPOINT), uint32(0)))
                    )
                ))
        );
        msig = t.owner();
        registry = new ChainRegistry(msig, unseeded());

        vm.startPrank(msig);
        provider = registry.addMessageProvider("layerzero");
        t.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Predetermined);
        vm.stopPrank();
    }

    /* ============================ the chainKey itself =========================== */

    /// @dev The point of the whole design. Both ends of a message derive the same key
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
    ///      one key and `ChainKey.fromIdentifier` accepts either form.
    function test_chainKeyIsStableAcrossAddressesOnAChain() public pure {
        bytes memory acct = Erc7930.encodeEvm(8453, address(0xBEEF));
        assertEq(ChainKey.fromIdentifier(acct), ChainKey.forEvm(8453));
    }

    /// @dev No chain is the anchor. A transceiver keeps no home of its own: an account's home
    ///      is a field of the account (`accountSalt`), and a delivery's origin is whichever
    ///      configured chain authenticated it.
    function test_aTransceiverHasNoHome() public view {
        (bool a,) = address(t).staticcall(abi.encodeWithSignature("homeChainKey()"));
        assertFalse(a, "no homeChainKey");
        (bool b,) = address(t).staticcall(abi.encodeWithSignature("homeRoute()"));
        assertFalse(b, "no homeRoute");
        (bool c,) = address(t).staticcall(abi.encodeWithSignature("homeTransceiver()"));
        assertFalse(c, "no homeTransceiver");
    }

    /* =========================== provider route table ========================== */

    function _wireBase() internal returns (bytes32 baseKey) {
        vm.startPrank(msig);
        baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453), Provenance.Predetermined);
        t.setCounterpart(baseKey, Erc7930.encodeEvm(8453, address(0xC0DE)));
        t.setRoute(baseKey, BASE_ROUTE);
        vm.stopPrank();
    }

    /// @dev The translation the transmitter never has to know about: it names Base as
    ///      `8453`, and the eid appears for the first time inside the transceiver.
    function test_chainKeyResolvesToTheProvidersOwnId() public {
        bytes32 baseKey = _wireBase();
        assertEq(t.routeTo(baseKey), BASE_ROUTE);
        assertEq(t.chainKeyOfRoute(BASE_ROUTE), baseKey, "and back again, for inbound");
    }

    /// @dev A route names exactly one chain: it must hash to its key, so another chain's
    ///      identifier is refused. Otherwise an inbound message from one chain would be
    ///      attributed to the other (#25).
    function test_oneRouteCannotNameTwoChains() public {
        bytes32 baseKey = _wireBase();
        vm.startPrank(msig);
        bytes32 arbKey = registry.addChainKey(Erc7930.encodeEvmChain(42161), Provenance.Predetermined);
        vm.expectRevert(abi.encodeWithSelector(OutboundBase.RouteKeyMismatch.selector, arbKey));
        t.setRoute(arbKey, BASE_ROUTE);
        vm.stopPrank();
        assertEq(t.chainKeyOfRoute(BASE_ROUTE), baseKey);
    }

    /// @dev Setting the same route twice is a no-op, not a self-collision.
    function test_rewritingTheSameRouteIsIdempotent() public {
        bytes32 baseKey = _wireBase();
        vm.prank(msig);
        t.setRoute(baseKey, BASE_ROUTE);
        assertEq(t.routeTo(baseKey), BASE_ROUTE);
    }

    /// @dev An unset route reverts rather than reading as eid 0, which is a real
    ///      LayerZero-adjacent value and would send into the void.
    function test_unsetRouteRevertsRatherThanReadingAsZero() public {
        vm.startPrank(msig);
        bytes32 key = registry.addChainKey(Erc7930.encodeEvmChain(10), Provenance.Predetermined);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(OutboundBase.NoRouteFor.selector, key));
        t.routeTo(key);
    }

    /// @dev Removal stops onboarding, not accounts: the transceiver keeps the counterpart it has, and
    ///      the chain accepts no new counterpart until it is added back.
    function test_removingAChainStopsOnboardingButNotItsTransceiver() public {
        vm.startPrank(msig);
        bytes32 key = registry.addChainKey(Erc7930.encodeEvmChain(10), Provenance.Predetermined);
        t.setCounterpart(key, Erc7930.encodeEvm(10, address(0xC0DE)));

        registry.removeChainKey(key);

        assertFalse(registry.hasChainKey(key));
        assertEq(uint8(registry.provenanceFor(key)), uint8(Provenance.Predetermined), "the declared grade stays");
        assertEq(t.counterpartOn(key), abi.encodePacked(address(0xC0DE)), "the transceiver still resolves it");

        vm.expectRevert(ChainRegistry.UnknownChainKey.selector);
        registry.validateLocation(key, Erc7930.encodeEvm(10, address(0xBEEF)));
        vm.stopPrank();
    }

    /// @dev Suspension still cuts a removed chain off: removal must not disable it.
    function test_aRemovedChainCanStillBeCutOff() public {
        vm.startPrank(msig);
        bytes32 key = registry.addChainKey(Erc7930.encodeEvmChain(10), Provenance.Predetermined);
        t.setCounterpart(key, Erc7930.encodeEvm(10, address(0xC0DE)));
        registry.removeChainKey(key);
        registry.setSuspended(key, true);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(TransceiverBase.ChainSuspended.selector, key));
        t.counterpartOn(key);
    }

    /// @dev A chain never registered has nothing to suspend.
    function test_aNeverRegisteredChainCannotBeSuspended() public {
        vm.prank(msig);
        vm.expectRevert(ChainRegistry.UnknownChainKey.selector);
        registry.setSuspended(keccak256("never registered"), true);
    }

    /// @dev The counterpart and the eid are configured separately and must be readable
    ///      separately: otherwise a half-wired chain cannot be diagnosed.
    function test_counterpartIsReadableWithoutAnEid() public {
        vm.startPrank(msig);
        bytes32 key = registry.addChainKey(Erc7930.encodeEvmChain(10), Provenance.Predetermined);
        t.setCounterpart(key, Erc7930.encodeEvm(10, address(0xC0DE)));
        vm.stopPrank();

        assertEq(t.counterpartOn(key).length, 20, "counterpart resolves");
        vm.expectRevert(abi.encodeWithSelector(OutboundBase.NoRouteFor.selector, key));
        t.routeTo(key);
    }

    function test_setProviderRouteIsOwnerGated() public {
        bytes32 baseKey = _wireBase();
        vm.expectRevert();
        t.setRoute(baseKey, ARB_ROUTE);
    }

    /// @dev A route cannot be repointed: a key has exactly one valid route, so pointing it
    ///      anywhere else names another chain, which is refused.
    function test_aRouteCannotBeRepointed() public {
        bytes32 baseKey = _wireBase();

        vm.prank(msig);
        vm.expectRevert(abi.encodeWithSelector(OutboundBase.RouteKeyMismatch.selector, baseKey));
        t.setRoute(baseKey, ARB_ROUTE);

        assertEq(t.routeTo(baseKey), BASE_ROUTE, "unchanged");
    }

    /// @dev The route lives where the sending happens. A registry read would put a second
    ///      shared contract in the path of every send, and a compromised one could
    ///      misroute a payload, which on the execute-on-arrival path means it runs on the
    ///      wrong chain, with no commitment binding the destination.
    function test_theRegistryHoldsNoRoutes() public {
        (bool a,) = address(registry)
            .call(abi.encodeWithSignature("setProviderRoute(bytes32,bytes32,bytes)", bytes32(0), bytes32(0), ""));
        assertFalse(a, "no setProviderRoute");

        (bool b,) = address(registry)
            .staticcall(abi.encodeWithSignature("providerRoute(bytes32,bytes32)", bytes32(0), bytes32(0)));
        assertFalse(b, "and no reader for one");
    }

    /* ================================= codec =================================== */

    /// @dev Fixed-width encoding, so a value configured at the wrong width fails in
    ///      `decode` rather than being silently reinterpreted as another chain.
    /// @dev A route that is not a canonical chain identifier is refused when it is set, not
    ///      left to fail when a recipient is first built from it. A mistyped provider id is
    ///      the usual way to get one.
    function test_aRouteThatIsNotAChainIdentifierIsRefused() public {
        vm.startPrank(msig);
        bytes32 key = registry.addChainKey(Erc7930.encodeEvmChain(10), Provenance.Predetermined);
        vm.expectRevert(abi.encodeWithSelector(OutboundBase.RouteKeyMismatch.selector, key));
        t.setRoute(key, abi.encodePacked(uint32(30111)));
        vm.stopPrank();

        assertFalse(t.hasRoute(key));
    }

    /// @dev An account envelope reduces to the right chain, but it is not the bare identifier
    ///      an inbound route arrives as, so inbound lookups would never match it.
    function test_anAccountEnvelopeIsNotARoute() public {
        bytes32 baseKey = ChainKey.forEvm(8453);
        vm.prank(msig);
        vm.expectRevert(abi.encodeWithSelector(OutboundBase.RouteKeyMismatch.selector, baseKey));
        t.setRoute(baseKey, Erc7930.encodeEvm(8453, address(0xBEEF)));
    }

    /// @dev `keccak256(identifier) == chainKey` is the definition of a chainKey, which is
    ///      what lets the route slot hold an identifier and the reverse index be correct
    ///      without being maintained.
    function testFuzz_aChainIdentifierRoundTripsToItsKey(uint256 chainId) public pure {
        vm.assume(chainId != 0);
        assertEq(ChainKey.fromIdentifier(Erc7930.encodeEvmChain(chainId)), ChainKey.forEvm(chainId));
    }
}
