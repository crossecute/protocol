// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Bytes32Set} from "src/registry/Bytes32Set.sol";

/// @dev A storage home for the library, since every function takes `Set storage`.
contract SetHarness {
    using Bytes32Set for Bytes32Set.Set;

    Bytes32Set.Set private _set;

    function add(bytes32 v) external returns (bool) {
        return _set.add(v);
    }

    function remove(bytes32 v) external returns (bool) {
        return _set.remove(v);
    }

    function contains(bytes32 v) external view returns (bool) {
        return _set.contains(v);
    }

    function length() external view returns (uint256) {
        return _set.length();
    }

    function at(uint256 i) external view returns (bytes32) {
        return _set.at(i);
    }

    function values() external view returns (bytes32[] memory) {
        return _set.values();
    }
}

/// @notice The set `ChainRegistry` keys its directory on.
///
/// @dev IT IS A FORK OF OPENZEPPELIN'S, so the thing worth testing is the branch a fork can
///      get wrong: swap-and-pop. Removing from the MIDDLE moves the last value into the
///      hole and has to follow it with its recorded position. Get that wrong and the set
///      corrupts SILENTLY: `contains` keeps answering true while `at` returns a different
///      value, which is exactly the failure a registry cannot afford and the one the
///      existing tests never reached, since they only ever removed a lone entry.
contract Bytes32SetTest is Test {
    SetHarness s;

    bytes32 constant A = keccak256("a");
    bytes32 constant B = keccak256("b");
    bytes32 constant C = keccak256("c");
    bytes32 constant D = keccak256("d");

    function setUp() public {
        s = new SetHarness();
    }

    function _fill() internal {
        s.add(A);
        s.add(B);
        s.add(C);
        s.add(D);
    }

    function _assertConsistent() internal view {
        uint256 n = s.length();
        bytes32[] memory vs = s.values();
        assertEq(vs.length, n, "values() disagrees with length()");
        for (uint256 i; i < n; ++i) {
            assertEq(s.at(i), vs[i], "at() disagrees with values()");
            assertTrue(s.contains(vs[i]), "an enumerated value is not contained");
        }
    }

    /* ================================== basics ================================= */

    function test_addReturnsFalseOnADuplicate() public {
        assertTrue(s.add(A));
        assertFalse(s.add(A), "already present");
        assertEq(s.length(), 1);
    }

    function test_removeReturnsFalseWhenAbsent() public {
        assertFalse(s.remove(A));
        s.add(A);
        assertTrue(s.remove(A));
        assertFalse(s.remove(A), "gone already");
    }

    function test_anEmptySetContainsNothing() public view {
        assertEq(s.length(), 0);
        assertEq(s.values().length, 0);
        assertFalse(s.contains(A));
        assertFalse(s.contains(bytes32(0)), "zero is a value like any other, and absent");
    }

    /// @dev Zero is not a sentinel in the VALUE space, only in the position space.
    function test_zeroIsAnOrdinaryMember() public {
        assertTrue(s.add(bytes32(0)));
        assertTrue(s.contains(bytes32(0)));
        assertEq(s.at(0), bytes32(0));
        assertTrue(s.remove(bytes32(0)));
        assertFalse(s.contains(bytes32(0)));
    }

    /* =============================== swap and pop ============================== */

    /// @dev THE BRANCH THE FORK COULD GET WRONG. Remove from the middle, and the last
    ///      value must land in the hole with its position followed.
    function test_removingFromTheMiddleKeepsEveryOtherValueReachable() public {
        _fill();

        assertTrue(s.remove(B), "B sat at index 1, D at index 3");

        assertEq(s.length(), 3);
        assertFalse(s.contains(B));
        assertTrue(s.contains(A));
        assertTrue(s.contains(C));
        assertTrue(s.contains(D), "the value that was moved is still findable");
        _assertConsistent();
    }

    /// @dev The moved value must be removable AFTERWARDS, which is what proves its position
    ///      was updated rather than left pointing at the slot it vacated.
    function test_theMovedValueCanItselfBeRemoved() public {
        _fill();
        s.remove(B);

        assertTrue(s.remove(D), "D was swapped into B's slot");
        assertEq(s.length(), 2);
        assertFalse(s.contains(D));
        assertTrue(s.contains(A));
        assertTrue(s.contains(C));
        _assertConsistent();
    }

    /// @dev Removing the LAST element takes the other branch: no swap at all.
    function test_removingTheTailNeedsNoSwap() public {
        _fill();
        assertTrue(s.remove(D));

        assertEq(s.length(), 3);
        assertEq(s.at(0), A);
        assertEq(s.at(1), B);
        assertEq(s.at(2), C, "the survivors kept their order");
        _assertConsistent();
    }

    /// @dev Re-adding after a removal must not resurrect a stale position.
    function test_reAddingAfterARemovalDoesNotDuplicate() public {
        _fill();
        s.remove(B);
        assertTrue(s.add(B), "absent, so this is a real add");
        assertFalse(s.add(B), "and now present");

        assertEq(s.length(), 4);
        _assertConsistent();
    }

    function test_removingEverythingEmptiesTheSet() public {
        _fill();
        s.remove(C);
        s.remove(A);
        s.remove(D);
        s.remove(B);

        assertEq(s.length(), 0);
        assertEq(s.values().length, 0);
        assertFalse(s.contains(A));
        assertFalse(s.contains(B));
        assertFalse(s.contains(C));
        assertFalse(s.contains(D));
    }

    function test_atRevertsPastTheEnd() public {
        s.add(A);
        vm.expectRevert();
        s.at(1);
    }

    /* ================================== fuzz =================================== */

    /// @dev The invariant, over an arbitrary interleaving: whatever the sequence, the three
    ///      views agree and membership matches a reference kept outside the set.
    function testFuzz_theSetAgreesWithAReferenceModel(bytes32[16] calldata ops, uint16 mask)
        public
    {
        bytes32[] memory seen = new bytes32[](16);
        bool[] memory present = new bool[](16);
        uint256 kinds;

        for (uint256 i; i < 16; ++i) {
            bytes32 v = ops[i];

            // Locate this value in the reference, or file it as new.
            uint256 slot = type(uint256).max;
            for (uint256 j; j < kinds; ++j) {
                if (seen[j] == v) {
                    slot = j;
                    break;
                }
            }
            if (slot == type(uint256).max) {
                slot = kinds++;
                seen[slot] = v;
            }

            if (mask & (1 << i) != 0) {
                assertEq(s.add(v), !present[slot], "add's return must mean 'was absent'");
                present[slot] = true;
            } else {
                assertEq(s.remove(v), present[slot], "remove's return must mean 'was present'");
                present[slot] = false;
            }
        }

        uint256 expected;
        for (uint256 j; j < kinds; ++j) {
            assertEq(s.contains(seen[j]), present[j], "membership diverged");
            if (present[j]) ++expected;
        }
        assertEq(s.length(), expected, "size diverged");
        _assertConsistent();
    }
}
