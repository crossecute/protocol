// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {IChainRegistryRoutes} from "src/registry/IChainRegistryRoutes.sol";
import {ChainType} from "src/addressing/ChainType.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {Provenance} from "src/registry/ForeignRef.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

contract RoutingTransceiver is HubTransceiverBase, OwnableUpgradeable {
    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
        __TransceiverBase_init();
    }

    /// @dev The mock supplies its own authority, exactly as a real protocol binding does.
    function _checkAdmin() internal view override {
        _checkOwner();
    }

    /// @dev Stands in for `_onInbound`, which decodes the payload and self-calls.
    function inboundReceiverReport(
        bytes32 chainKey,
        address transmitter,
        bytes calldata interop
    ) external {
        this.onDestinationReceiver(chainKey, transmitter, interop);
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
    bytes32 constant SALT = keccak256("xsafe.transceiver.lz.v1");
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
            IChainRegistryRoutes(address(registry)), provider, Provenance.Derived
        );
        vm.stopPrank();
    }

    /// @dev Same factory, same salt, same initcode — so Ethereum recomputes the Base
    ///      counterpart locally at `Derived`. No message, no bridge trust.
    function test_evmCounterpartIsDerivedNotBridged() public {
        vm.startPrank(msig);
        bytes32 baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        bytes32 id =
            keccak256(abi.encode("lz", uint256(8453)));
        registry.resolveEvmCreate2(id, 8453, FACTORY, SALT, INIT_CODE_HASH);
        registry.setTransceiverId(baseKey, provider, id);
        vm.stopPrank();

        address expected = AddressDerive.create2(FACTORY, SALT, INIT_CODE_HASH);
        bytes memory location = transceiver.counterpartOn(baseKey);
        assertEq(abi.decode(abi.encodePacked(bytes12(0), location), (address)), expected);
        assertEq(
            uint8(registry.requireRef(id, Provenance.Derived).provenance),
            uint8(Provenance.Derived),
            "no bridge trust involved"
        );
    }

    /// @dev The same salt lands at the same address on every chain sharing Ethereum's
    ///      derivation — which is why no redeploy or repointing is ever needed.
    function test_sameAddressAcrossEvmChains() public {
        vm.startPrank(msig);
        bytes32 baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        bytes32 arbKey = registry.addChainKey(Erc7930.encodeEvmChain(42161));

        bytes32 baseId = keccak256("lz.base");
        bytes32 arbId = keccak256("lz.arb");
        registry.resolveEvmCreate2(baseId, 8453, FACTORY, SALT, INIT_CODE_HASH);
        registry.resolveEvmCreate2(arbId, 42161, FACTORY, SALT, INIT_CODE_HASH);
        registry.setTransceiverId(baseKey, provider, baseId);
        registry.setTransceiverId(arbKey, provider, arbId);
        vm.stopPrank();

        assertEq(
            transceiver.counterpartOn(baseKey),
            transceiver.counterpartOn(arbKey),
            "one address covers every EVM destination"
        );
    }

    /// @dev A chain that can only reach `Attested` is refused while the bar is `Derived`.
    ///      This is the dial that decides whether Solana or Sui are reachable at all.
    function test_counterpartBelowProvenanceBarIsRefused() public {
        bytes memory solChain =
            Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");
        bytes memory solAccount = Erc7930.encode(
            ChainType.SOLANA, hex"0102030405060708", abi.encodePacked(keccak256("prog"))
        );

        vm.startPrank(msig);
        bytes32 solKey = registry.addChainKey(solChain);
        registry.setLocalTransceiver(provider, msig);
        vm.stopPrank();

        // Attested: the destination asserted it and nothing here checks.
        vm.prank(msig);
        registry.onForeignRefResolved(keccak256("lz.sol"), solAccount, "");

        // The route is DECLARED by the owner, not learned from the callback.
        vm.prank(msig);
        registry.setTransceiverId(solKey, provider, keccak256("lz.sol"));

        vm.expectRevert(ChainRegistry.InsufficientProvenance.selector);
        transceiver.counterpartOn(solKey);

        // Lowering the bar makes it reachable — explicitly, not by accident.
        vm.prank(msig);
        transceiver.setRouting(
            IChainRegistryRoutes(address(registry)), provider, Provenance.Attested
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

    /// @dev Starknet's address derivation is Pedersen and cannot run on the EVM at any
    ///      price. So the destination creates the receiver, reports the address back, and
    ///      the registry grades it `Attested` — an honest description of what we know.
    function test_starknetReceiverLearnedFromCallback() public {
        bytes memory snChain = Erc7930.encodeChainId(ChainType.STARKNET, bytes("SN_MAIN"));
        // A felt below L2_ADDRESS_UPPER_BOUND, zero-padded to the required 32 bytes.
        bytes memory snAddr = abi.encodePacked(bytes32(uint256(1) << 200));
        bytes memory snReceiver = Erc7930.encode(ChainType.STARKNET, bytes("SN_MAIN"), snAddr);

        address transmitter = address(0x7A11);

        vm.startPrank(msig);
        bytes32 snKey = registry.addChainKey(snChain);
        // Starknet can never honestly reach Derived; make that unrepresentable.
        registry.setMaxProvenance(snKey, Provenance.Committed);
        registry.setLocalTransceiver(provider, address(transceiver));
        transceiver.setRouting(
            IChainRegistryRoutes(address(registry)), provider, Provenance.Attested
        );
        vm.stopPrank();

        // Nothing known yet.
        vm.expectRevert(ChainRegistry.NotResolved.selector);
        transceiver.destinationReceiverOn(snKey, transmitter);

        transceiver.inboundReceiverReport(snKey, transmitter, snReceiver);

        assertEq(transceiver.destinationReceiverOn(snKey, transmitter), snAddr);

        // Graded Attested: worth exactly the bridge's security, and no more.
        bytes32 slot = registry.receiverSlot(snKey, transmitter);
        assertEq(
            uint8(registry.get(slot).provenance), uint8(Provenance.Attested)
        );
        // A caller demanding a stronger grade is refused.
        vm.expectRevert(ChainRegistry.InsufficientProvenance.selector);
        registry.destinationReceiverOf(snKey, transmitter, Provenance.Committed);
    }

    /// @dev A receiver must not land in the transceiver route table.
    function test_receiverReportDoesNotTouchRouteTable() public {
        bytes memory snChain = Erc7930.encodeChainId(ChainType.STARKNET, bytes("SN_MAIN"));
        bytes memory snReceiver = Erc7930.encode(
            ChainType.STARKNET, bytes("SN_MAIN"), abi.encodePacked(bytes32(uint256(1) << 200))
        );
        address transmitter = address(0x7A11);

        vm.startPrank(msig);
        bytes32 snKey = registry.addChainKey(snChain);
        registry.setMaxProvenance(snKey, Provenance.Committed);
        registry.setLocalTransceiver(provider, address(transceiver));
        vm.stopPrank();

        transceiver.inboundReceiverReport(snKey, transmitter, snReceiver);
        assertEq(registry.transceiverIdOf(snKey, provider), bytes32(0));
    }

    function test_receiverCallbackIsSelfCallOnly() public {
        vm.expectRevert();
        transceiver.onDestinationReceiver(keccak256("k"), address(0x7A11), "");
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

        assertEq(registry.transceiverIdOf(baseKey, provider), bytes32(0), "nothing declared");
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
    function test_anExplicitRouteOverridesTheDefault() public {
        vm.startPrank(msig);
        bytes32 baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        registry.setLocalTransceiver(provider, address(transceiver));

        bytes32 id = keccak256("lz.base.explicit");
        registry.resolveEvmCreate2(id, 8453, FACTORY, SALT, INIT_CODE_HASH);
        registry.setTransceiverId(baseKey, provider, id);
        vm.stopPrank();

        address expected = AddressDerive.create2(FACTORY, SALT, INIT_CODE_HASH);
        assertEq(transceiver.counterpartOn(baseKey), abi.encodePacked(expected));
        assertTrue(expected != address(transceiver), "and it is not the default");
    }

    /// @dev A 20-byte EVM address means nothing on Solana. There is no default there, and
    ///      inventing one would be a claim about an address that does not exist.
    function test_thereIsNoDefaultOnANonEvmChain() public {
        vm.startPrank(msig);
        bytes32 solKey =
            registry.addChainKey(Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708"));
        registry.setLocalTransceiver(provider, address(transceiver));
        vm.stopPrank();

        vm.expectRevert(ChainRegistry.NoCounterpart.selector);
        transceiver.counterpartOn(solKey);
    }

    /// @dev THE zkSYNC AND TRON CASE. Both are `eip155`, so the chain type alone says
    ///      parity might hold — and both have different CREATE2 formulas, so it does not.
    ///      `setMaxProvenance` is already the dial that records "addresses here cannot be
    ///      recomputed on Ethereum", so a cap below `Derived` withdraws the default rather
    ///      than needing a second flag that could disagree with it.
    function test_aChainCappedBelowDerivedGetsNoDefault() public {
        vm.startPrank(msig);
        bytes32 zkKey = registry.addChainKey(Erc7930.encodeEvmChain(324));
        registry.setLocalTransceiver(provider, address(transceiver));
        registry.setMaxProvenance(zkKey, Provenance.Committed);
        vm.stopPrank();

        vm.expectRevert(ChainRegistry.NoCounterpart.selector);
        transceiver.counterpartOn(zkKey);

        // Declaring one explicitly still works — that is what the cap forces you to do,
        // and the cap is also why it can only ever be learned rather than derived.
        bytes32 id = keccak256("lz.zksync");
        vm.prank(address(transceiver));
        registry.onForeignRefResolved(id, Erc7930.encodeEvm(324, address(0xACE5)), "");

        vm.startPrank(msig);
        registry.setTransceiverId(zkKey, provider, id);
        transceiver.setRouting(
            IChainRegistryRoutes(address(registry)), provider, Provenance.Attested
        );
        vm.stopPrank();

        assertEq(transceiver.counterpartOn(zkKey), abi.encodePacked(address(0xACE5)));
    }

    function test_thereIsNoDefaultWithoutALocalTransceiver() public {
        vm.prank(msig);
        bytes32 baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));

        vm.expectRevert(ChainRegistry.NoLocalTransceiver.selector);
        transceiver.counterpartOn(baseKey);
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
            IChainRegistryRoutes(address(registry)), provider, Provenance.Attested
        );
    }
}
