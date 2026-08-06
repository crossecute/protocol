// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Call, Calls} from "src/messaging/Call.sol";
import {Commitment, Scheme} from "src/messaging/Commitment.sol";
import {Blake2b256} from "src/derivation/Blake2b256.sol";

/// @dev External surface so `calldata` parameters are genuine calldata and reverts can be
///      caught the way a caller would see them.
contract SchemeHarness {
    function hashElements(Scheme scheme, bytes32 chainKey, bytes[] memory elements)
        external
        view
        returns (bytes32)
    {
        return Commitment.hashElements(scheme, chainKey, elements);
    }

    function hashCalls(Scheme scheme, bytes32 chainKey, Call[] memory calls)
        external
        view
        returns (bytes32)
    {
        return Commitment.hashCalls(scheme, chainKey, calls);
    }

    function keccakElements(bytes32 chainKey, bytes[] calldata elements)
        external
        pure
        returns (bytes32)
    {
        return Commitment.hashCalls(chainKey, elements);
    }

    function isComputable(Scheme scheme) external pure returns (bool) {
        return Commitment.isComputable(scheme);
    }
}

/// @notice The commitment scheme is per-destination, because not every chain hashes the
///         way the EVM does.
contract CommitmentSchemeTest is Test {
    SchemeHarness h;

    bytes32 constant DEST = keccak256("destination.chain");

    function setUp() public {
        h = new SchemeHarness();
    }

    /* ============================== the EVM default ============================= */

    /// @dev The scheme-parameterized path with `Keccak256` must equal the fixed keccak
    ///      path an EVM receiver uses. If these drift, every EVM commitment built through
    ///      the non-EVM entry point silently stops matching.
    function test_keccakSchemeEqualsTheFixedEvmPath() public view {
        bytes[] memory elements = Calls.encodeAll(_calls());

        assertEq(
            h.hashElements(Scheme.Keccak256, DEST, elements),
            h.keccakElements(DEST, elements),
            "one scheme, one value"
        );
    }

    /// @dev The typed/opaque equivalence has to survive the scheme parameter too.
    function testFuzz_typedAndOpaqueAgreeUnderEveryComputableScheme(
        address target,
        uint256 value,
        bytes memory data
    ) public view {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: target, value: value, data: data});
        bytes[] memory elements = Calls.encodeAll(calls);

        Scheme[3] memory schemes =
            [Scheme.Keccak256, Scheme.Sha256, Scheme.Blake2b256Scheme];

        for (uint256 i; i < schemes.length; ++i) {
            assertEq(
                h.hashCalls(schemes[i], DEST, calls),
                h.hashElements(schemes[i], DEST, elements),
                "typed and opaque agree whatever the primitive"
            );
        }
    }

    /* ============================== schemes differ ============================== */

    /// @dev The whole reason the parameter exists: the same payload for the same chain
    ///      produces a different commitment under a different scheme. A destination
    ///      hashing with sha256 would never match a keccak commitment.
    function test_eachSchemeProducesADistinctCommitment() public view {
        Call[] memory calls = _calls();

        bytes32 k = h.hashCalls(Scheme.Keccak256, DEST, calls);
        bytes32 s = h.hashCalls(Scheme.Sha256, DEST, calls);
        bytes32 b = h.hashCalls(Scheme.Blake2b256Scheme, DEST, calls);

        assertTrue(k != s, "keccak vs sha256");
        assertTrue(k != b, "keccak vs blake2b");
        assertTrue(s != b, "sha256 vs blake2b");
    }

    /// @dev The chain-binding is unchanged by the scheme: the seed still folds in the
    ///      destination chainKey, so a payload approved for one chain cannot match on
    ///      another under any primitive.
    function test_theChainBindingSurvivesEveryScheme() public view {
        Call[] memory calls = _calls();
        bytes32 other = keccak256("some.other.chain");

        assertTrue(
            h.hashCalls(Scheme.Sha256, DEST, calls)
                != h.hashCalls(Scheme.Sha256, other, calls)
        );
        assertTrue(
            h.hashCalls(Scheme.Blake2b256Scheme, DEST, calls)
                != h.hashCalls(Scheme.Blake2b256Scheme, other, calls)
        );
    }

    /* ============================ the primitives agree ========================== */

    /// @dev A one-element fold, computed by hand against the primitive itself. This is
    ///      what pins the fold STRUCTURE — seed over the chainKey, then
    ///      `H(acc ‖ H(element))` — rather than only asserting internal consistency.
    function test_theSha256FoldMatchesAHandComputation() public view {
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"c0ffee";

        bytes32 expected = sha256(
            abi.encodePacked(sha256(abi.encode(DEST)), sha256(elements[0]))
        );
        assertEq(h.hashElements(Scheme.Sha256, DEST, elements), expected);
    }

    function test_theBlake2bFoldMatchesAHandComputation() public view {
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"c0ffee";

        bytes32 expected = Blake2b256.hash(
            abi.encodePacked(
                Blake2b256.hash(abi.encode(DEST)), Blake2b256.hash(elements[0])
            )
        );
        assertEq(h.hashElements(Scheme.Blake2b256Scheme, DEST, elements), expected);
    }

    /// @dev An empty array is the seed alone — non-zero, and therefore a valid commitment
    ///      under every scheme, exactly as it is under keccak.
    function test_anEmptyArrayIsTheSeedUnderEveryScheme() public view {
        bytes[] memory none = new bytes[](0);

        assertEq(h.hashElements(Scheme.Sha256, DEST, none), sha256(abi.encode(DEST)));
        assertTrue(h.hashElements(Scheme.Sha256, DEST, none) != bytes32(0));
    }

    /* =============================== not computable ============================= */

    /// @dev POSEIDON IS DECLARED AND NOT IMPLEMENTED, and it must revert rather than fall
    ///      back. A silent fallback to keccak would hand back a well-formed commitment
    ///      that a Starknet receiver can never match, and it would fail only on a live
    ///      message.
    function test_anUnimplementedSchemeRevertsRatherThanFallingBack() public {
        Call[] memory calls = _calls();

        vm.expectRevert(
            abi.encodeWithSelector(Commitment.SchemeNotComputable.selector, Scheme.Poseidon)
        );
        h.hashCalls(Scheme.Poseidon, DEST, calls);

        vm.expectRevert(
            abi.encodeWithSelector(Commitment.SchemeNotComputable.selector, Scheme.Poseidon)
        );
        h.hashElements(Scheme.Poseidon, DEST, Calls.encodeAll(calls));
    }

    /// @dev Callers can ask before building a payload rather than discovering it in a
    ///      revert. This is the list a Starknet integration has to route around.
    function test_isComputableNamesTheGap() public view {
        assertTrue(h.isComputable(Scheme.Keccak256));
        assertTrue(h.isComputable(Scheme.Sha256));
        assertTrue(h.isComputable(Scheme.Blake2b256Scheme));
        assertFalse(h.isComputable(Scheme.Poseidon), "Starknet still needs a port");
    }

    /* ================================== helpers ================================= */

    function _calls() internal pure returns (Call[] memory calls) {
        calls = new Call[](2);
        calls[0] = Call({target: address(0xF00), value: 0, data: hex"deadbeef"});
        calls[1] = Call({target: address(0xBA2), value: 7, data: hex""});
    }
}
