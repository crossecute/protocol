// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "test/Deployment.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ChainType} from "src/addressing/ChainType.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Move} from "src/addressing/Move.sol";
import {MoveValidator} from "src/validators/MoveValidator.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

contract Hub is HubTransceiverBase {
    function initialize(address owner_) external initializer {
        __TransceiverBase_init(Deploy.ownedBy(owner_));
    }

    /// @dev A HARNESS TRUSTS ANY GATEWAY, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }

}

/// @notice The counterpart directory after it moved off the registry.
///
/// @dev THE SPLIT IS THE POINT, AND IT IS ONE LINE: the hub holds WHERE a counterpart is,
///      because that is per provider and two providers put two transceivers on one chain;
///      the registry holds WHAT A CLAIM ABOUT THAT CHAIN IS WORTH, because that is the same
///      question for every provider and two hubs must not be able to answer it differently.
contract HubCounterpartsTest is Test {
    ChainRegistry registry;
    Hub hub;

    address owner = address(0xA11CE);
    bytes32 suiChainKey;
    bytes32 provider;
    bytes suiInterop;

    function setUp() public {
        registry = ChainRegistry(
            address(
                new ERC1967Proxy(
                    address(new ChainRegistry()),
                    abi.encodeCall(ChainRegistry.initialize, (owner))
                )
            )
        );
        hub = Hub(
            address(
                new ERC1967Proxy(
                    address(new Hub()), abi.encodeCall(Hub.initialize, (owner))
                )
            )
        );

        bytes memory suiChain = Erc7930.encodeChainId(ChainType.SUI, bytes("mainnet"));
        suiInterop = Erc7930.encode(
            ChainType.SUI, bytes("mainnet"), abi.encodePacked(keccak256("pkg"))
        );

        vm.startPrank(owner);
        suiChainKey = registry.addChainKey(suiChain);
        registry.setValidator(suiChainKey, new MoveValidator());
        registry.setProvenance(suiChainKey, Provenance.Attested);
        provider = registry.addMessageProvider("layerzero");
        registry.setLocalTransceiver(provider, address(hub));
        hub.setRouting(
            IChainRegistryRefs(address(registry)), provider, Provenance.Attested
        );
        vm.stopPrank();
    }

    function _qualifier() internal pure returns (Move.MoveQualifier memory q) {
        q.kind = Move.MoveKind.Entry;
        q.moduleName = "transceiver";
        q.functionName = "receive_message";
    }

    /* ============================== the directory =============================== */

    function test_theHubHoldsTheAddressAndTheRegistryTheGrade() public {
        vm.prank(owner);
        hub.setCounterpart(suiChainKey, suiInterop);

        assertEq(hub.counterpartOn(suiChainKey), Erc7930.parseStrict(suiInterop).addr);
        assertEq(uint8(registry.provenanceFor(suiChainKey)), uint8(Provenance.Attested));
    }

    /// @dev TWO PROVIDERS, TWO ADDRESSES, ONE GRADE. That is the whole reason the two halves
    ///      live where they do: a second hub records its own transceiver on the same chain
    ///      without displacing the first, and neither can decide the chain is worth more
    ///      than the registry says.
    function test_twoHubsHoldSeparateAddressesAndShareTheGrade() public {
        Hub second = Hub(
            address(
                new ERC1967Proxy(
                    address(new Hub()), abi.encodeCall(Hub.initialize, (owner))
                )
            )
        );
        bytes memory other = Erc7930.encode(
            ChainType.SUI, bytes("mainnet"), abi.encodePacked(keccak256("other"))
        );

        vm.startPrank(owner);
        bytes32 p2 = registry.addMessageProvider("hyperlane");
        second.setRouting(
            IChainRegistryRefs(address(registry)), p2, Provenance.Attested
        );
        hub.setCounterpart(suiChainKey, suiInterop);
        second.setCounterpart(suiChainKey, other);
        vm.stopPrank();

        assertTrue(
            keccak256(hub.counterpartOn(suiChainKey))
                != keccak256(second.counterpartOn(suiChainKey)),
            "each provider its own transceiver"
        );
        assertEq(
            uint8(registry.provenanceFor(suiChainKey)),
            uint8(Provenance.Attested),
            "one grade, and neither hub can move it"
        );
    }

    function test_aCounterpartIsWriteOnce() public {
        bytes memory other = Erc7930.encode(
            ChainType.SUI, bytes("mainnet"), abi.encodePacked(keccak256("other"))
        );
        vm.startPrank(owner);
        hub.setCounterpart(suiChainKey, suiInterop);
        vm.expectRevert(
            abi.encodeWithSelector(
                HubTransceiverBase.CounterpartAlreadySet.selector, suiChainKey
            )
        );
        hub.setCounterpart(suiChainKey, other);
        vm.stopPrank();
    }

    function test_settingACounterpartIsAdminGated() public {
        vm.expectRevert();
        hub.setCounterpart(suiChainKey, suiInterop);
    }

    /// @dev THE VALIDATOR STAYED ON THE REGISTRY WHEN THE STORAGE LEFT, because what makes
    ///      an address well-formed is a property of the chain. One validator per chain
    ///      serves every provider's hub rather than each carrying its own copy.
    function test_theChainsValidatorStillRuns() public {
        // 31 bytes: a Move address is 32, and the envelope alone cannot express that.
        bytes memory short = Erc7930.encode(
            ChainType.SUI, bytes("mainnet"), new bytes(31)
        );
        vm.prank(owner);
        vm.expectRevert();
        hub.setCounterpart(suiChainKey, short);
    }

    function test_aCounterpartOnTheWrongChainIsRefused() public {
        vm.startPrank(owner);
        registry.addChainKey(Erc7930.encodeEvmChain(1));
        vm.expectRevert(ChainRegistry.UnknownChainKey.selector);
        hub.setCounterpart(suiChainKey, Erc7930.encodeEvm(1, address(0xCAFE)));
        vm.stopPrank();
    }

    /* ============================== Move qualifiers ============================= */

    /// @dev THE QUALIFIER FOLLOWS THE COUNTERPART, because it qualifies one: a Move call
    ///      target is `address::module::function`, and the address alone does not name it.
    function test_aQualifierAttachesToACounterpart() public {
        Move.MoveQualifier memory q = _qualifier();
        vm.startPrank(owner);
        hub.setCounterpart(suiChainKey, suiInterop);
        hub.setQualifier(suiChainKey, q);
        vm.stopPrank();

        assertEq(hub.qualifier(suiChainKey).functionName, "receive_message");
    }

    function test_aQualifierNeedsACounterpartFirst() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(OutboundBase.NoCounterpartFor.selector, suiChainKey)
        );
        hub.setQualifier(suiChainKey, _qualifier());
    }

    /// @dev Validated against the chain it sits on, so a malformed Move identifier never
    ///      lands and an EVM chain cannot acquire one.
    function test_aMalformedQualifierIsRefused() public {
        Move.MoveQualifier memory q = _qualifier();
        q.moduleName = "not a module name";

        vm.startPrank(owner);
        hub.setCounterpart(suiChainKey, suiInterop);
        vm.expectRevert();
        hub.setQualifier(suiChainKey, q);
        vm.stopPrank();
    }

    /// @dev Re-setting the SAME qualifier is a no-op; a DIFFERENT one reverts, because
    ///      re-pointing a live call target is the same operation as re-pointing the address.
    function test_theQualifierIsIdempotentButNotRepointable() public {
        Move.MoveQualifier memory q = _qualifier();
        vm.startPrank(owner);
        hub.setCounterpart(suiChainKey, suiInterop);
        hub.setQualifier(suiChainKey, q);
        hub.setQualifier(suiChainKey, q);

        q.functionName = "something_else";
        vm.expectRevert(
            abi.encodeWithSelector(
                HubTransceiverBase.QualifierMismatch.selector, suiChainKey
            )
        );
        hub.setQualifier(suiChainKey, q);
        vm.stopPrank();
    }

    function test_readingAnAbsentQualifierReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(HubTransceiverBase.NoQualifier.selector, suiChainKey)
        );
        hub.qualifier(suiChainKey);
    }
}
