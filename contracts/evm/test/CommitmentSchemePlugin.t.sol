// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {ICommitmentScheme} from "src/registry/ICommitmentScheme.sol";
import {Commitment, Scheme} from "src/messaging/Commitment.sol";
import {Blake2b256} from "src/derivation/Blake2b256.sol";
import {ChainType} from "src/addressing/ChainType.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

import {KeccakScheme} from "src/schemes/KeccakScheme.sol";
import {Sha256Scheme} from "src/schemes/Sha256Scheme.sol";
import {Blake2bScheme} from "src/schemes/Blake2bScheme.sol";

/* ============================ the simulated new chain ========================== */

/// @notice A primitive with NO MEMBER IN `Scheme`, which is the entire point of it.
///         Bitcoin's hash256 — sha256 applied twice — standing in for whatever a chain
///         onboarded after every live transmitter was compiled turns out to hash with.
/// @dev Chosen because it is real, plausible as a destination's choice, and computable
///      from EVM builtins, so the test asserts a value rather than a mock.
contract Sha256dScheme is ICommitmentScheme {
    function hash(bytes calldata data) external pure override returns (bytes32) {
        return sha256(abi.encodePacked(sha256(data)));
    }
}

/// @notice Stands in for a real Poseidon port. IT IS NOT POSEIDON and must never be
///         registered against a live Starknet chainKey.
/// @dev It exists to prove one thing: that `Scheme.Poseidon` reverting
///      `SchemeNotComputable` on every frozen transmitter is a gap the SEAM closes,
///      independently of anyone having written the round constants yet.
contract NotReallyPoseidonScheme is ICommitmentScheme {
    function hash(bytes calldata data) external pure override returns (bytes32) {
        return keccak256(abi.encodePacked("poseidon-stand-in", data));
    }
}

/// @notice Returns a constant, ignoring its input entirely.
/// @dev The adversary the interface is shaped against. It can corrupt its own digest and
///      nothing else — the fold stays in the registry, so the commitment's STRUCTURE is
///      not a plugin's to choose.
contract ConstantScheme is ICommitmentScheme {
    bytes32 constant C = bytes32(uint256(0xC0FFEE));

    function hash(bytes calldata) external pure override returns (bytes32) {
        return C;
    }
}

/* ================================ the harness ================================= */

/// @dev The library is `internal`, so reaching it the way a caller would needs a
///      deployed surface.
contract LibraryHarness {
    function frozenEvmPath(bytes32 chainKey, bytes[] calldata elements)
        external
        pure
        returns (bytes32)
    {
        return Commitment.hashCalls(chainKey, elements);
    }

    function enumPath(Scheme scheme, bytes32 chainKey, bytes[] memory elements)
        external
        view
        returns (bytes32)
    {
        return Commitment.hashCalls(scheme, chainKey, elements);
    }
}

/// @notice Covers the claim that a chain onboarded later, hashing in a way nobody had
///         written when the live accounts were compiled, is PREVIEWABLE without touching
///         a single frozen contract.
///
/// @dev The seam only earns its place if it reproduces the frozen fold exactly. A preview
///      that merely resembles what the destination enforces is worse than no preview: it
///      reads as confirmation and is not one. Every primitive the enum already carries is
///      asserted equal here, and only then is a new one added.
contract CommitmentSchemePluginTest is Test {
    ChainRegistry registry;
    LibraryHarness lib;

    KeccakScheme keccakScheme;
    Sha256Scheme sha256Scheme;
    Blake2bScheme blake2bScheme;
    Sha256dScheme sha256dScheme;

    address owner = address(0xA11CE);
    address stranger = address(0xBAD);

    /// @dev A chain type with no `ChainType` constant and no `parseStrict` rule.
    ///      `Erc7930` documents that such a value parses and registers, which is what
    ///      lets a genuinely new chain family reach this seam at all.
    uint16 constant CT_UNALLOCATED = 0xFF7A;

    bytes32 evmKey;
    bytes32 tonKey;
    bytes32 cardanoKey;
    bytes32 newChainKey;
    bytes32 starknetKey;

    function setUp() public {
        lib = new LibraryHarness();
        keccakScheme = new KeccakScheme();
        sha256Scheme = new Sha256Scheme();
        blake2bScheme = new Blake2bScheme();
        sha256dScheme = new Sha256dScheme();

        ChainRegistry impl = new ChainRegistry();
        registry = ChainRegistry(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(ChainRegistry.initialize, (owner))
                )
            )
        );

        vm.startPrank(owner);
        evmKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        tonKey = registry.addChainKey(Erc7930.encodeChainId(ChainType.NEAR, hex"01"));
        cardanoKey = registry.addChainKey(Erc7930.encodeChainId(ChainType.COSMOS, hex"02"));
        starknetKey = registry.addChainKey(
            Erc7930.encodeChainId(ChainType.STARKNET, bytes("SN_MAIN"))
        );

        registry.setCommitmentScheme(evmKey, keccakScheme);
        registry.setCommitmentScheme(tonKey, sha256Scheme);
        registry.setCommitmentScheme(cardanoKey, blake2bScheme);
        vm.stopPrank();
    }

    function _elements() internal pure returns (bytes[] memory elements) {
        elements = new bytes[](3);
        elements[0] = abi.encode(address(0xBEEF), uint256(1 ether), bytes("first"));
        elements[1] = hex"";
        elements[2] = abi.encodePacked("an opaque element no EVM contract parses");
    }

    /* ================== the seam reproduces the frozen fold =================== */

    /// @dev THE LOAD-BEARING ASSERTION. `ReceiverBase` enforces with the keccak fold
    ///      compiled into it and can never be changed. If the plugin path disagrees here,
    ///      every preview it ever produces is a lie, and it fails only on a live message.
    function test_pluginPathReproducesTheFrozenEvmPath() public view {
        bytes[] memory elements = _elements();
        assertEq(
            registry.commitmentFor(evmKey, elements),
            lib.frozenEvmPath(evmKey, elements),
            "plugin fold diverged from the fold a receiver enforces"
        );
    }

    /// @dev The two other primitives already in the enum, for the same reason. No
    ///      transmitter can be asked for these any more — the overload that took a
    ///      `Scheme` is gone — so the registry is the only surface that answers. Pinning
    ///      it to the library keeps the enum honest as the reference implementation of a
    ///      fold that non-EVM receivers are written against.
    function test_pluginPathReproducesEveryEnumScheme() public view {
        bytes[] memory elements = _elements();

        assertEq(
            registry.commitmentFor(evmKey, elements),
            lib.enumPath(Scheme.Keccak256, evmKey, elements),
            "keccak"
        );
        assertEq(
            registry.commitmentFor(tonKey, elements),
            lib.enumPath(Scheme.Sha256, tonKey, elements),
            "sha256"
        );
        assertEq(
            registry.commitmentFor(cardanoKey, elements),
            lib.enumPath(Scheme.Blake2b256Scheme, cardanoKey, elements),
            "blake2b"
        );
    }

    /// @dev An empty payload hashes to the seed alone — non-zero, and therefore a valid
    ///      commitment. Matches the library, which `finalize` relies on.
    function test_emptyElementsHashToTheSeedAlone() public view {
        bytes[] memory none = new bytes[](0);
        bytes32 got = registry.commitmentFor(evmKey, none);

        assertEq(got, keccak256(abi.encode(evmKey)));
        assertEq(got, lib.frozenEvmPath(evmKey, none));
        assertTrue(got != bytes32(0));
    }

    /// @dev THE CAPABILITY MOVED, IT WAS NOT DROPPED. `TransmitterBase` used to answer
    ///      this shape through `commitmentForChain(bytes, Scheme, bytes[])`, which was
    ///      removed because a preview frozen with the account can only ever name
    ///      primitives that already existed. For a destination the enum DOES cover, the
    ///      registry returns the identical value — so nothing a signer could ask before
    ///      has become unanswerable, it is asked somewhere that can still learn.
    function test_theRegistryAnswersTheShapeTheTransmitterNoLongerDoes() public {
        bytes memory sol = Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");

        vm.startPrank(owner);
        bytes32 solKey = registry.addChainKey(sol);
        registry.setCommitmentScheme(solKey, keccakScheme);
        vm.stopPrank();

        bytes[] memory elements = _elements();
        assertEq(
            registry.commitmentFor(solKey, elements),
            lib.enumPath(Scheme.Keccak256, solKey, elements),
            "the value the removed overload returned"
        );
    }

    /* ======================= onboarding a NEW primitive ======================= */

    /// @dev THE WHOLE POINT. A chain whose hash has no `Scheme` member, on a chain type
    ///      with no `ChainType` constant, becomes previewable with one owner transaction.
    ///      No account is redeployed, no frozen bytecode is consulted, and every chain
    ///      already wired keeps answering exactly as before.
    function test_newSchemeNeedsNoEnumMemberAndNoRedeploy() public {
        bytes[] memory elements = _elements();
        bytes32 evmBefore = registry.commitmentFor(evmKey, elements);

        vm.startPrank(owner);
        newChainKey =
            registry.addChainKey(Erc7930.encodeChainId(CT_UNALLOCATED, hex"2a"));
        registry.setCommitmentScheme(newChainKey, sha256dScheme);
        vm.stopPrank();

        // The value the destination's own receiver would compute, folded independently
        // here rather than read back from the code under test.
        bytes32 want = _sha256dFold(newChainKey, elements);
        assertEq(registry.commitmentFor(newChainKey, elements), want);

        // It is genuinely a different primitive, not keccak wearing a hat.
        assertTrue(registry.commitmentFor(newChainKey, elements) != evmBefore);

        // Every chain configured before it is untouched.
        assertEq(registry.commitmentFor(evmKey, elements), evmBefore);
        assertEq(
            registry.commitmentFor(tonKey, elements),
            lib.enumPath(Scheme.Sha256, tonKey, elements)
        );
    }

    /// @dev The new primitive is unreachable through the frozen enum in either
    ///      direction: there is no member to name it with, and every member that does
    ///      exist produces a different digest.
    function test_newSchemeIsUnreachableThroughTheEnum() public {
        vm.startPrank(owner);
        newChainKey =
            registry.addChainKey(Erc7930.encodeChainId(CT_UNALLOCATED, hex"2a"));
        registry.setCommitmentScheme(newChainKey, sha256dScheme);
        vm.stopPrank();

        bytes[] memory elements = _elements();
        bytes32 got = registry.commitmentFor(newChainKey, elements);

        assertTrue(got != lib.enumPath(Scheme.Keccak256, newChainKey, elements));
        assertTrue(got != lib.enumPath(Scheme.Sha256, newChainKey, elements));
        assertTrue(got != lib.enumPath(Scheme.Blake2b256Scheme, newChainKey, elements));
    }

    /// @dev `Scheme.Poseidon` is declared and reverts on every frozen transmitter, so
    ///      Starknet commitments have to be computed off-chain today. The seam closes
    ///      that with a deployment rather than a redeploy — whenever someone ports the
    ///      real thing against a vector corpus.
    function test_poseidonBecomesPreviewableThroughThePlugin() public {
        bytes[] memory elements = _elements();

        vm.expectRevert(
            abi.encodeWithSelector(Commitment.SchemeNotComputable.selector, Scheme.Poseidon)
        );
        lib.enumPath(Scheme.Poseidon, starknetKey, elements);

        ICommitmentScheme stub = new NotReallyPoseidonScheme();
        vm.prank(owner);
        registry.setCommitmentScheme(starknetKey, stub);

        assertTrue(registry.commitmentFor(starknetKey, elements) != bytes32(0));
    }

    /* ============================ the fold is not the plugin's ================= */

    /// @dev A plugin that ignores its input entirely still cannot choose the SHAPE of the
    ///      commitment: the registry seeds with the chainKey and folds per element, so
    ///      the result is the fold applied to that constant rather than the constant.
    ///      That is what makes a swappable plugin bounded — the worst case is a digest
    ///      the destination refuses, never a differently-structured one it accepts.
    function test_aHostilePluginCannotChangeTheFold() public {
        ICommitmentScheme hostile = new ConstantScheme();
        vm.prank(owner);
        registry.setCommitmentScheme(evmKey, hostile);

        bytes32 c = bytes32(uint256(0xC0FFEE));
        bytes[] memory elements = _elements();

        // Seed, then one fold per element — every call returning the same constant.
        assertEq(registry.commitmentFor(evmKey, elements), c);
        // And the element count still drives the loop: an empty array is the seed alone.
        assertEq(registry.commitmentFor(evmKey, new bytes[](0)), c);
    }

    /// @dev The chainKey is the seed, and the plugin never sees which chain it is
    ///      hashing for. Cross-chain replay protection therefore survives a hostile
    ///      plugin, because it is not the plugin's to weaken.
    function test_theChainKeyIsFoldedInAndIsNotThePluginsBusiness() public {
        vm.startPrank(owner);
        bytes32 otherKey = registry.addChainKey(Erc7930.encodeEvmChain(42161));
        registry.setCommitmentScheme(otherKey, keccakScheme);
        vm.stopPrank();

        bytes[] memory elements = _elements();
        assertTrue(
            registry.commitmentFor(evmKey, elements)
                != registry.commitmentFor(otherKey, elements),
            "same elements on two chains must not share a commitment"
        );
    }

    /* ================================ the seam ================================ */

    /// @dev Rebindable, unlike a route. A wrong primitive is the one part of the
    ///      commitment story that has to be fixable, since everything downstream of it
    ///      is frozen.
    function test_schemeIsRebindable() public {
        bytes[] memory elements = _elements();
        bytes32 before = registry.commitmentFor(evmKey, elements);

        vm.prank(owner);
        registry.setCommitmentScheme(evmKey, sha256Scheme);

        assertTrue(registry.commitmentFor(evmKey, elements) != before);
        assertEq(
            registry.commitmentFor(evmKey, elements),
            lib.enumPath(Scheme.Sha256, evmKey, elements)
        );
    }

    /// @dev Withdrawing a plugin makes the preview revert rather than answer. A signer
    ///      who cannot get an answer goes and computes one; a signer given a wrong answer
    ///      approves it.
    function test_unregisteringMakesThePreviewRefuseRatherThanGuess() public {
        vm.prank(owner);
        registry.setCommitmentScheme(evmKey, ICommitmentScheme(address(0)));

        vm.expectRevert(ChainRegistry.NoCommitmentScheme.selector);
        registry.commitmentFor(evmKey, _elements());
    }

    /// @dev No silent keccak fallback for a chain nobody configured — the same rule
    ///      `Commitment._hash` follows, for the same reason.
    function test_unconfiguredChainRefusesRatherThanFallingBackToKeccak() public {
        vm.prank(owner);
        bytes32 unconfigured = registry.addChainKey(Erc7930.encodeEvmChain(10));

        vm.expectRevert(ChainRegistry.NoCommitmentScheme.selector);
        registry.commitmentFor(unconfigured, _elements());
    }

    function test_schemeMustBeAttachedToAKnownChain() public {
        vm.prank(owner);
        vm.expectRevert(ChainRegistry.UnknownChainKey.selector);
        registry.setCommitmentScheme(keccak256("never.registered"), keccakScheme);
    }

    function test_onlyOwnerMaySetAScheme() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.setCommitmentScheme(evmKey, sha256Scheme);
    }

    function test_settingASchemeIsObservable() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit ChainRegistry.CommitmentSchemeSet(evmKey, address(sha256Scheme));
        vm.prank(owner);
        registry.setCommitmentScheme(evmKey, sha256Scheme);

        assertEq(address(registry.commitmentSchemeOf(evmKey)), address(sha256Scheme));
    }

    /* ================================ reference =============================== */

    /// @dev The fold, written out longhand against the new primitive. Deliberately not
    ///      expressed in terms of anything under test.
    function _sha256dFold(bytes32 chainKey, bytes[] memory elements)
        private
        pure
        returns (bytes32 acc)
    {
        acc = _sha256d(abi.encode(chainKey));
        for (uint256 i = 0; i < elements.length; i++) {
            acc = _sha256d(abi.encodePacked(acc, _sha256d(elements[i])));
        }
    }

    function _sha256d(bytes memory data) private pure returns (bytes32) {
        return sha256(abi.encodePacked(sha256(data)));
    }
}
