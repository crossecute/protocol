// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {IRefValidator} from "src/registry/IRefValidator.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainType} from "src/addressing/ChainType.sol";
import {VmDeriver, IVmDeriver} from "src/derivation/VmDeriver.sol";

/// @dev Rejects any address that is not exactly 8 bytes, standing in for the value-range
///      rule a real CAIP-350 profile would bring.
contract WidthValidator is IRefValidator {
    error BadWidth(uint256 got);

    function validateRef(bytes calldata interop) external pure {
        uint256 n = Erc7930.parseStrict(interop).addr.length;
        if (n != 8) revert BadWidth(n);
    }
}

/// @notice Whether the registry accepts a ChainType it has never heard of.
///
/// @dev `ChainType.sol` is an allocation table, not an enum. Every value is a plain
///      `uint16` and nothing validates against the set, so the question is not whether an
///      unknown type parses (it does), but which parts of the registry still work and
///      which quietly do not.
contract UnknownChainTypeTest is Test {
    ChainRegistry registry;

    address owner = address(0xA11CE);
    address transceiver = address(0x7BAD);
    bytes32 provider;

    /// A value allocated to nothing in `ChainType.sol`, and below the provisional floor.
    uint16 constant CT_UNKNOWN = 0x0042;

    bytes chainId;
    bytes account;

    function setUp() public {
        registry = new ChainRegistry(owner);
        chainId = Erc7930.encodeChainId(CT_UNKNOWN, hex"cafe");
        account = Erc7930.encode(CT_UNKNOWN, hex"cafe", hex"0011223344556677");

        vm.startPrank(owner);
        provider = registry.addMessageProvider("layerzero");
        registry.setLocalTransceiver(provider, transceiver);
        vm.stopPrank();
    }

    /* ================================ what works =============================== */

    /// @dev The envelope is the only gate, and it does not know the table. `parseStrict`
    ///      reads the chain type as an opaque `uint16`; it never checks it against
    ///      `ChainType.sol`.
    function test_anUndefinedChainTypeRegisters() public {
        vm.prank(owner);
        bytes32 chainKey = registry.addChainKey(chainId, Provenance.Unresolved);

        assertTrue(registry.hasChainKey(chainKey));
        assertEq(registry.chainIdentifier(chainKey), chainId);
        assertEq(chainKey, keccak256(chainId), "the key is just the envelope hash");
    }

    /// @dev The directory is chain-type-agnostic: a chain nothing here has ever heard of
    ///      can be registered and graded, because grading is about how well an address can
    ///      be known rather than about what the address means.
    function test_theDirectoryWorksForAnUndefinedChainType() public {
        vm.startPrank(owner);
        bytes32 chainKey = registry.addChainKey(chainId, Provenance.Attested);
        vm.stopPrank();

        assertEq(uint8(registry.provenanceFor(chainKey)), uint8(Provenance.Attested));
        assertTrue(
            registry.requiresReceiverCallback(chainKey),
            "nothing here can derive an address on a chain type it does not know"
        );
    }

    /// @dev Address parity is an `eip155` argument, so an unknown chain type cannot be graded
    ///      `Derived`: a 20-byte EVM address means nothing there, and a transceiver that
    ///      assumed one would address the void.
    function test_anUndefinedChainTypeCannotBeGradedDerived() public {
        vm.prank(owner);
        vm.expectRevert(ChainRegistry.NotEvmChain.selector);
        registry.addChainKey(chainId, Provenance.Derived);
    }

    /// @dev The two per-chain extension points are wired by `chainKey`, not by chain type,
    ///      so both are available immediately.
    function test_validatorAndCapAttachToAnUndefinedChainType() public {
        vm.startPrank(owner);
        bytes32 chainKey = registry.addChainKey(chainId, Provenance.Attested);
        registry.setValidator(chainKey, new WidthValidator());
        vm.stopPrank();

        // The validator is enforced wherever a location is checked, which is now the
        // transceiver's setter calling back into `validateLocation`.
        bytes memory wrongWidth = Erc7930.encode(CT_UNKNOWN, hex"cafe", hex"00112233");
        vm.expectRevert(abi.encodeWithSelector(WidthValidator.BadWidth.selector, 4));
        registry.validateLocation(chainKey, wrongWidth);

        // And a well-formed one passes.
        registry.validateLocation(chainKey, account);
    }

    /* =============================== what does not ============================= */

    /// @dev The uniform derivation is closed, and this is the one place a new chain type
    ///      needs code rather than configuration. `supportsScheme` is a fixed dispatch, so
    ///      the stock deriver rejects every scheme for a type it does not know.
    function test_theStockDeriverSupportsNoSchemeForAnUndefinedChainType() public {
        VmDeriver d = new VmDeriver();
        for (uint8 scheme; scheme < 20; ++scheme) {
            assertFalse(d.supportsScheme(CT_UNKNOWN, scheme), "no scheme is legal for an unknown VM");
        }

        vm.startPrank(owner);
        bytes32 chainKey = registry.addChainKey(chainId, Provenance.Unresolved);
        registry.setDeriver(chainKey, IVmDeriver(address(d)));
        vm.expectRevert(ChainRegistry.SchemeNotSupported.selector);
        registry.setDeriveParams(chainKey, abi.encode(uint8(0), bytes("")));
        vm.stopPrank();
    }

    /* ================================ the hazard =============================== */

    /// @dev The real gap, and it is silent. `parseStrict` carries canonicity rules only
    ///      for the profiles it knows: minimal chain references for `eip155`, fixed
    ///      32-byte addresses for `starknet`. An unregistered chain type gets no rule, so
    ///      two encodings of what a human would call one address both parse, both are
    ///      "canonical", and they hash to different keys.
    ///
    ///      That is precisely the split-brain the registry's whole canonicity argument
    ///      exists to prevent, and adding a `ChainType` constant does not close it: the
    ///      rule has to be written into `parseStrict` alongside it.
    function test_anUndefinedChainTypeHasNoCanonicityRule() public {
        bytes memory padded = Erc7930.encode(CT_UNKNOWN, hex"00cafe", hex"0011223344556677");
        bytes memory minimal = Erc7930.encode(CT_UNKNOWN, hex"cafe", hex"0011223344556677");

        // Both parse. Neither is rejected as non-minimal.
        Erc7930.parseStrict(padded);
        Erc7930.parseStrict(minimal);

        assertTrue(
            Erc7930.chainKey(padded) != Erc7930.chainKey(minimal),
            "one chain, two keys: nothing here says which is canonical"
        );

        // And both register, as two unrelated chains.
        vm.startPrank(owner);
        bytes32 a = registry.addChainKey(padded, Provenance.Unresolved);
        bytes32 b = registry.addChainKey(minimal, Provenance.Unresolved);
        vm.stopPrank();

        assertTrue(a != b);
        assertEq(registry.chainKeyCount(), 2, "a split-brain the registry cannot see");
    }

    /// @dev By contrast, `eip155` has a rule and it fires.
    function test_eip155RejectsTheSameNonMinimalEncoding() public {
        bytes memory padded = Erc7930.encode(ChainType.EIP155, hex"0001", hex"");

        vm.prank(owner);
        vm.expectRevert(Erc7930.NonMinimalChainRef.selector);
        registry.addChainKey(padded, Provenance.Derived);
    }
}
