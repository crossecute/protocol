// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "test/Deployment.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {ChainType} from "src/addressing/ChainType.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

contract RoutingTransceiver is HubTransceiverBase {
    function initialize(address owner_) external initializer {
        __TransceiverBase_init(Deploy.ownedBy(owner_));
    }

    /// @dev Stands in for `_onInbound`, which decodes the payload and self-calls.

    /// @dev A HARNESS TRUSTS ANY GATEWAY, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }

}

/// @notice The source transceiver asks the registry where its counterpart lives, rather
///         than assuming it shares its own address. That assumption holds on most EVM
///         chains and breaks on zkSync, Tron, and every non-EVM chain.
contract CounterpartRoutingTest is Test {
    ChainRegistry registry;
    RoutingTransceiver transceiver;

    address msig = address(0x5165);
    bytes32 provider;

    /// The single CREATE2 address every EVM counterpart shares.
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant SALT = keccak256("crossecute.transceiver.lz.v1");
    bytes32 constant INIT_CODE_HASH = keccak256("lz-transceiver-initcode");

    function setUp() public {
        registry = ChainRegistry(
            address(
                new ERC1967Proxy(
                    address(new ChainRegistry()),
                    abi.encodeCall(ChainRegistry.initialize, (msig))
                )
            )
        );
        transceiver = RoutingTransceiver(
            address(
                new ERC1967Proxy(
                    address(new RoutingTransceiver()),
                    abi.encodeCall(RoutingTransceiver.initialize, (msig))
                )
            )
        );

        vm.startPrank(msig);
        provider = registry.addMessageProvider("layerzero");
        transceiver.setRouting(
            IChainRegistryRefs(address(registry)), provider, Provenance.Derived
        );
        vm.stopPrank();
    }

    /// @dev THE HUB HOLDS THE ADDRESS, THE REGISTRY HOLDS WHAT IT IS WORTH. A location is
    ///      per provider, because two providers deploy two transceivers to one chain; the
    ///      grade is per chain, because how well an address there can be known is the same
    ///      question for both. So this writes the address here and reads the grade there.
    function test_theHubStoresTheAddressAndTheRegistryGradesTheChain() public {
        vm.startPrank(msig);
        bytes32 baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        vm.stopPrank();

        address expected = AddressDerive.create2(FACTORY, SALT, INIT_CODE_HASH);
        vm.prank(msig);
        transceiver.setCounterpart(baseKey, Erc7930.encodeEvm(8453, expected));

        assertEq(transceiver.counterpartOn(baseKey), abi.encodePacked(expected));
        assertEq(
            uint8(registry.provenanceFor(baseKey)),
            uint8(Provenance.Derived),
            "an eip155 chain is derivable unless declared otherwise"
        );
    }

    /// @dev WRITE-ONCE, LIKE A ROUTE. A counterpart names the contract every message to that
    ///      chain authenticates against, so re-pointing one redirects the whole destination.
    function test_aCounterpartIsWriteOnce() public {
        vm.prank(msig);
        bytes32 baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));

        vm.startPrank(msig);
        transceiver.setCounterpart(baseKey, Erc7930.encodeEvm(8453, address(0xA)));
        vm.expectRevert(
            abi.encodeWithSelector(
                HubTransceiverBase.CounterpartAlreadySet.selector, baseKey
            )
        );
        transceiver.setCounterpart(baseKey, Erc7930.encodeEvm(8453, address(0xB)));
        vm.stopPrank();
    }

    /// @dev A LOCATION MUST BE ON THE CHAIN IT IS FILED UNDER, and the registry is what says
    ///      so: the validation stayed there when the storage left, because what makes an
    ///      address well-formed is a property of the chain.
    function test_aCounterpartOnTheWrongChainIsRefused() public {
        vm.startPrank(msig);
        bytes32 baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        registry.addChainKey(Erc7930.encodeEvmChain(42161));

        vm.expectRevert(ChainRegistry.UnknownChainKey.selector);
        transceiver.setCounterpart(baseKey, Erc7930.encodeEvm(42161, address(0xA)));
        vm.stopPrank();
    }

    /// @dev The same default lands at the same address on every chain sharing Ethereum's
    ///      derivation, which is why no redeploy or repointing is ever needed.
    function test_sameAddressAcrossEvmChains() public {
        vm.startPrank(msig);
        bytes32 baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        bytes32 arbKey = registry.addChainKey(Erc7930.encodeEvmChain(42161));
        registry.setLocalTransceiver(provider, address(transceiver));
        vm.stopPrank();

        assertEq(
            transceiver.counterpartOn(baseKey),
            transceiver.counterpartOn(arbKey),
            "one address covers every EVM destination"
        );
    }

    /// @dev A chain the registry grades `Attested` is refused while the bar is `Derived`.
    ///      This is the dial that decides whether Solana or Sui are reachable at all.
    function test_counterpartBelowProvenanceBarIsRefused() public {
        bytes memory solChain =
            Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");
        bytes memory solAccount = Erc7930.encode(
            ChainType.SOLANA, hex"0102030405060708", abi.encodePacked(keccak256("prog"))
        );

        vm.startPrank(msig);
        bytes32 solKey = registry.addChainKey(solChain);
        registry.setProvenance(solKey, Provenance.Attested);
        transceiver.setCounterpart(solKey, solAccount);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                HubTransceiverBase.InsufficientCounterpartProvenance.selector,
                solKey,
                Provenance.Attested
            )
        );
        transceiver.counterpartOn(solKey);

        // Lowering the bar makes it reachable: explicitly, not by accident.
        vm.prank(msig);
        transceiver.setRouting(
            IChainRegistryRefs(address(registry)), provider, Provenance.Attested
        );
        assertEq(transceiver.counterpartOn(solKey).length, 32);
    }

    function test_routingRequiresRegistry() public {
        RoutingTransceiver bare = RoutingTransceiver(
            address(
                new ERC1967Proxy(
                    address(new RoutingTransceiver()),
                    abi.encodeCall(RoutingTransceiver.initialize, (msig))
                )
            )
        );
        vm.expectRevert(HubTransceiverBase.NoChainRegistry.selector);
        bare.counterpartOn(keccak256("anything"));
    }

    /// @dev THE REGISTRY SAYS WHICH CHAINS REPORT, AND HOLDS NO RECEIVER DATA. Starknet's
    ///      address derivation is Pedersen and cannot run on the EVM at any price, so the
    ///      destination has to create the receiver and report it back. WHICH chains are like
    ///      that is a property of the chain and belongs in this directory; WHERE a given
    ///      account's receiver landed is a property of that account and lives on its
    ///      transmitter, which is also the only contract that reads it. The round trip is
    ///      covered in `ReceiverReport.t.sol`.
    function test_theRegistrySaysWhichChainsReport() public {
        bytes memory snChain = Erc7930.encodeChainId(ChainType.STARKNET, bytes("SN_MAIN"));

        vm.startPrank(msig);
        bytes32 snKey = registry.addChainKey(snChain);
        bytes32 baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        vm.stopPrank();

        assertTrue(
            registry.requiresReceiverCallback(snKey), "Pedersen: not derivable here"
        );
        assertFalse(
            registry.requiresReceiverCallback(baseKey), "parity: derived locally"
        );
    }

    /// @dev IT IS DERIVED FROM THE CAPS RATHER THAN DECLARED, so it cannot disagree with
    ///      them. zkSync and Tron are the case that needs this: they ARE `eip155`, so chain
    ///      type alone says they are derivable, and the cap is what records that their
    ///      CREATE2 formula differs. One fact, read two ways, rather than two flags.
    function test_theReportingFlagFollowsTheProvenanceCap() public {
        vm.startPrank(msig);
        bytes32 zkKey = registry.addChainKey(Erc7930.encodeEvmChain(324));
        assertFalse(registry.requiresReceiverCallback(zkKey), "eip155, uncapped");

        registry.setProvenance(zkKey, Provenance.Attested);
        assertTrue(registry.requiresReceiverCallback(zkKey), "capped below Derived");
        vm.stopPrank();
    }

    function test_receiverCallbackIsSelfCallOnly() public {
        vm.expectRevert();
        transceiver.onDestinationReceiver(keccak256("k"), address(0x7A11), bytes32(0), "");
    }

    /* =========================== the default counterpart ======================== */

    /// @dev THE COMMON CASE NEEDS NO CONFIGURATION AT ALL. A transceiver is deployed as a
    ///      proxy through Nick's factory, so hub and spoke share initcode and salt and
    ///      land on one address wherever Ethereum's CREATE2 formula holds. The local
    ///      transceiver's own address is therefore the right answer for every such chain,
    ///      and a per-chain table would be rows all saying the same thing.
    function test_anUnsetRouteDefaultsToTheLocalTransceiver() public {
        vm.startPrank(msig);
        bytes32 baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        registry.setLocalTransceiver(provider, address(transceiver));
        vm.stopPrank();

        assertEq(
            transceiver.counterpartOn(baseKey),
            abi.encodePacked(address(transceiver)),
            "address parity is the default"
        );
    }

    /// @dev One local transceiver covers every EVM destination at once, which is the
    ///      whole point of the parity argument.
    function test_theDefaultCoversEveryEvmChainAtOnce() public {
        vm.startPrank(msig);
        bytes32 baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        bytes32 arbKey = registry.addChainKey(Erc7930.encodeEvmChain(42161));
        registry.setLocalTransceiver(provider, address(transceiver));
        vm.stopPrank();

        assertEq(transceiver.counterpartOn(baseKey), transceiver.counterpartOn(arbKey));
    }

    /// @dev An explicit declaration wins. This is the escape hatch for every chain where
    ///      parity does not hold.
    function test_anExplicitCounterpartOverridesTheDefault() public {
        vm.startPrank(msig);
        bytes32 baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        registry.setLocalTransceiver(provider, address(transceiver));
        transceiver.setCounterpart(baseKey, Erc7930.encodeEvm(8453, address(0xACE5)));
        vm.stopPrank();

        assertEq(transceiver.counterpartOn(baseKey), abi.encodePacked(address(0xACE5)));
    }

    function test_thereIsNoDefaultOnANonEvmChain() public {
        vm.startPrank(msig);
        bytes32 solKey =
            registry.addChainKey(Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708"));
        registry.setLocalTransceiver(provider, address(transceiver));
        vm.stopPrank();

        // Unresolved, which no bar accepts: nothing here can derive a Solana address, so
        // a default would be a guess rather than a shortcut.
        vm.expectRevert(
            abi.encodeWithSelector(
                HubTransceiverBase.InsufficientCounterpartProvenance.selector,
                solKey,
                Provenance.Unresolved
            )
        );
        transceiver.counterpartOn(solKey);
    }

    /// @dev THE zkSYNC AND TRON CASE. Both are `eip155`, so the chain type alone says
    ///      parity might hold, and both have different CREATE2 formulas, so it does not.
    ///      `setProvenance` is already the dial that records "addresses here cannot be
    ///      recomputed on the hub", so a cap below `Derived` withdraws the default rather
    ///      than needing a second flag that could disagree with it.
    function test_aChainGradedBelowDerivedGetsNoDefault() public {
        vm.startPrank(msig);
        bytes32 zkKey = registry.addChainKey(Erc7930.encodeEvmChain(324));
        registry.setLocalTransceiver(provider, address(transceiver));
        registry.setProvenance(zkKey, Provenance.Attested);
        transceiver.setRouting(
            IChainRegistryRefs(address(registry)), provider, Provenance.Attested
        );
        vm.stopPrank();

        // The default withdraws: the hub's own address is only the right answer where
        // Ethereum's formula holds, which is exactly what `Derived` records.
        vm.expectRevert(
            abi.encodeWithSelector(OutboundBase.NoCounterpartFor.selector, zkKey)
        );
        transceiver.counterpartOn(zkKey);

        // Declaring one explicitly is what the grade forces you to do.
        vm.prank(msig);
        transceiver.setCounterpart(zkKey, Erc7930.encodeEvm(324, address(0xACE5)));
        assertEq(transceiver.counterpartOn(zkKey), abi.encodePacked(address(0xACE5)));
    }

    /// @dev THE HUB IS ITS OWN FALLBACK NOW, so there is nothing to be missing. The
    ///      registry used to answer the default out of `localTransceiver`, which meant a
    ///      provider with none had no counterpart anywhere; the hub answers it from
    ///      `address(this)`, which it always has. `localTransceiver` still names the hub
    ///      that speaks for a provider, but nothing on the send path reads it.
    function test_theHubIsItsOwnDefault() public {
        vm.prank(msig);
        bytes32 baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));

        assertEq(
            transceiver.counterpartOn(baseKey),
            abi.encodePacked(address(transceiver)),
            "no registry configuration needed at all"
        );
    }

    function test_theDefaultIsRefusedForAnUnregisteredChain() public {
        vm.prank(msig);
        registry.setLocalTransceiver(provider, address(transceiver));

        vm.expectRevert(ChainRegistry.UnknownChainKey.selector);
        transceiver.counterpartOn(keccak256("never.registered"));
    }

    function test_setRoutingIsOwnerGated() public {
        vm.expectRevert();
        transceiver.setRouting(
            IChainRegistryRefs(address(registry)), provider, Provenance.Attested
        );
    }
}
