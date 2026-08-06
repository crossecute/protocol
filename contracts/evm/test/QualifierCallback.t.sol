// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainType} from "src/addressing/ChainType.sol";
import {Provenance} from "src/registry/ForeignRef.sol";
import {Move} from "src/addressing/Move.sol";
import {MoveValidator} from "src/validators/MoveValidator.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice The destination callback after the expectation machinery was removed.
///
/// @dev THE GUARANTEES ARE STRUCTURAL, NOT REGISTERED IN ADVANCE. The caller must be a
///      registered local transceiver, the slot is derived from the authenticated pair
///      rather than chosen by the message, and it may be written exactly once. Nothing has
///      to be declared before the send for any of that to hold.
contract QualifierCallbackTest is Test {
    ChainRegistry registry;

    address owner = address(0xA11CE);
    address transceiver = address(0x7BAD);
    address otherTransceiver = address(0x7BAE);
    bytes32 constant SLOT = keccak256("sui.transceiver");

    bytes32 suiChainKey;
    bytes32 provider;
    bytes suiInterop;

    function setUp() public {
        ChainRegistry impl = new ChainRegistry();
        registry = ChainRegistry(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(ChainRegistry.initialize, (owner))
                )
            )
        );

        bytes memory suiChain = Erc7930.encodeChainId(ChainType.SUI, bytes("mainnet"));
        suiInterop =
            Erc7930.encode(ChainType.SUI, bytes("mainnet"), abi.encodePacked(keccak256("pkg")));

        vm.startPrank(owner);
        suiChainKey = registry.addChainKey(suiChain);
        registry.setValidator(suiChainKey, new MoveValidator());
        provider = registry.addMessageProvider("layerzero");
        registry.setLocalTransceiver(provider, transceiver);
        vm.stopPrank();
    }

    function _qualifier() internal pure returns (Move.MoveQualifier memory q) {
        q.kind = Move.MoveKind.Entry;
        q.moduleName = "transceiver";
        q.functionName = "receive_message";
    }

    /* ============================== authentication ============================== */

    /// @dev THE CALLER IS THE AUTHORITY. Nothing else in the message says who sent it.
    function test_onlyARegisteredLocalTransceiverMayReport() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(ChainRegistry.NotTransceiver.selector);
        registry.onForeignRefResolved(SLOT, suiInterop, "");
    }

    /// @dev The provider is a property of `msg.sender`, not a claim the message makes.
    ///      A second provider gets its own hub, which is what the single-address
    ///      `sourceTransceiver` could never express.
    function test_eachProviderHasItsOwnReportingTransceiver() public {
        vm.startPrank(owner);
        bytes32 second = registry.addMessageProvider("hyperlane");
        registry.setLocalTransceiver(second, otherTransceiver);
        vm.stopPrank();

        assertEq(registry.providerOfTransceiver(transceiver), provider);
        assertEq(registry.providerOfTransceiver(otherTransceiver), second);

        // Both can report, to different slots.
        vm.prank(transceiver);
        registry.onForeignRefResolved(SLOT, suiInterop, "");
        vm.prank(otherTransceiver);
        registry.onForeignRefResolved(keccak256("sui.transceiver.2"), suiInterop, "");
    }

    /// @dev Retiring a transceiver removes its authority, rather than leaving a second
    ///      address able to report for the same provider forever.
    function test_repointingAProviderRevokesTheOldTransceiver() public {
        vm.prank(owner);
        registry.setLocalTransceiver(provider, otherTransceiver);

        assertEq(registry.providerOfTransceiver(transceiver), bytes32(0));

        vm.prank(transceiver);
        vm.expectRevert(ChainRegistry.NotTransceiver.selector);
        registry.onForeignRefResolved(SLOT, suiInterop, "");
    }

    /* ================================ write-once ================================ */

    /// @dev THE GUARANTEE THAT REPLACED `Committed`. A receiver's address is a fact
    ///      established once; a second report is a replay or a repoint, and a compromised
    ///      bridge gets to do neither.
    function test_aResolvedSlotCannotBeRewritten() public {
        vm.prank(transceiver);
        registry.onForeignRefResolved(SLOT, suiInterop, "");

        bytes memory elsewhere = Erc7930.encode(
            ChainType.SUI, bytes("mainnet"), abi.encodePacked(keccak256("attacker"))
        );

        vm.prank(transceiver);
        vm.expectRevert(ChainRegistry.AlreadyResolved.selector);
        registry.onForeignRefResolved(SLOT, elsewhere, "");

        // The original survives untouched.
        assertEq(registry.get(SLOT).id, Erc7930.id(suiInterop));
    }

    /// @dev Not even an identical repeat gets through — a replayed message is a revert,
    ///      not a silent no-op that looks like success.
    function test_evenAnIdenticalReportIsRefusedTwice() public {
        vm.prank(transceiver);
        registry.onForeignRefResolved(SLOT, suiInterop, "");

        vm.prank(transceiver);
        vm.expectRevert(ChainRegistry.AlreadyResolved.selector);
        registry.onForeignRefResolved(SLOT, suiInterop, "");
    }

    /// @dev Write-once is per slot, so one chain's report never blocks another's.
    function test_writeOnceIsPerSlot() public {
        vm.prank(transceiver);
        registry.onForeignRefResolved(SLOT, suiInterop, "");
        vm.prank(transceiver);
        registry.onForeignRefResolved(keccak256("sui.other"), suiInterop, "");

        assertEq(registry.get(keccak256("sui.other")).id, Erc7930.id(suiInterop));
    }

    /* ================================= grading ================================== */

    /// @dev With nothing registered in advance the honest grade is `Attested` — worth
    ///      exactly the security of the bridge that carried it, and no more.
    function test_aReportedRefIsAttestedAndNothingMore() public {
        vm.prank(transceiver);
        registry.onForeignRefResolved(SLOT, suiInterop, "");

        assertEq(uint8(registry.get(SLOT).provenance), uint8(Provenance.Attested));

        vm.expectRevert(ChainRegistry.InsufficientProvenance.selector);
        registry.requireRef(SLOT, Provenance.Committed);
    }

    /* ================================ qualifiers ================================ */

    /// @dev The qualifier travels WITH the address, because a Move call target is
    ///      `address::module::function` and the address alone does not identify it. It has
    ///      no provenance of its own and inherits the grade of the ref it attaches to.
    function test_aReportedQualifierIsStoredWithTheRef() public {
        Move.MoveQualifier memory q = _qualifier();

        vm.prank(transceiver);
        registry.onForeignRefResolved(SLOT, suiInterop, abi.encode(q));

        assertEq(registry.get(SLOT).qualifierHash, Move.hash(q));
        assertEq(registry.qualifier(SLOT).functionName, "receive_message");
    }

    /// @dev A qualifier is validated against the chain it claims to be on, so Sui-only
    ///      fields on an Aptos ref — or a malformed Move identifier — never land.
    function test_aMalformedQualifierIsRefused() public {
        Move.MoveQualifier memory q = _qualifier();
        q.moduleName = "not a module name";

        vm.prank(transceiver);
        vm.expectRevert();
        registry.onForeignRefResolved(SLOT, suiInterop, abi.encode(q));
    }

    /// @dev Chains with no qualified names pass empty bytes and are unaffected.
    function test_nonMoveChainNeedsNoQualifier() public {
        vm.prank(owner);
        bytes32 ethKey = registry.addChainKey(Erc7930.encodeEvmChain(1));

        bytes memory ethInterop = Erc7930.encodeEvm(1, address(0xCAFE));
        vm.prank(transceiver);
        registry.onForeignRefResolved(keccak256("eth.tx"), ethInterop, "");

        assertEq(registry.get(keccak256("eth.tx")).chainKey, ethKey);
        assertEq(registry.evmAddress(keccak256("eth.tx")), address(0xCAFE));
    }

    /* ================================== routing ================================= */

    /// @dev THE CALLBACK DOES NOT WRITE THE ROUTE. A route says which contract every
    ///      message to a chain authenticates against, so letting a destination's report
    ///      set it would hand that choice to the party being authenticated. It is an owner
    ///      declaration, and write-once.
    function test_theCallbackDoesNotWriteTheRoute() public {
        vm.prank(transceiver);
        registry.onForeignRefResolved(SLOT, suiInterop, "");

        assertEq(
            registry.transceiverIdOf(suiChainKey, provider),
            bytes32(0),
            "a report is evidence, not a routing decision"
        );
    }

    function test_theOwnerDeclaresTheRouteAndOnlyOnce() public {
        vm.prank(transceiver);
        registry.onForeignRefResolved(SLOT, suiInterop, "");

        vm.prank(owner);
        registry.setTransceiverId(suiChainKey, provider, SLOT);

        (bytes32 id,) = registry.transceiverFor(suiChainKey, provider, Provenance.Attested);
        assertEq(id, SLOT);

        // Re-pointing is a redeploy, not a config edit.
        vm.prank(owner);
        vm.expectRevert(ChainRegistry.AlreadySet.selector);
        registry.setTransceiverId(suiChainKey, provider, keccak256("somewhere.else"));
    }

    /// @dev Re-writing the SAME id is a no-op, so a replayed configuration transaction is
    ///      not a failure.
    function test_rewritingTheSameRouteIsIdempotent() public {
        vm.prank(transceiver);
        registry.onForeignRefResolved(SLOT, suiInterop, "");

        vm.startPrank(owner);
        registry.setTransceiverId(suiChainKey, provider, SLOT);
        registry.setTransceiverId(suiChainKey, provider, SLOT);
        vm.stopPrank();

        assertEq(registry.transceiverIdOf(suiChainKey, provider), SLOT);
    }
}
