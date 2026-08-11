// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Bytes32Set
/// @notice OpenZeppelin's `EnumerableSet.Bytes32Set`, minus the one overload that reaches a
///         Cancun-only opcode.
///
/// @dev IT IS A FORK TO AVOID AN OPCODE, NOT TO CHANGE BEHAVIOUR. `EnumerableSet` began
///      importing `Arrays` in 5.3 for its PAGINATED `values(start, end)`, and `Arrays`
///      began using `mcopy` in 5.5. Nothing in this repo calls the paginated form, but an
///      import compiles the file it names, and that file will not compile at `paris`. The
///      build is pinned there because PUSH0 is absent on zkSync, Tron, and several L2s, and
///      identical initcode everywhere is what the whole CREATE2 address story rests on: see
///      `foundry.toml`. So the dependency goes rather than the pin.
///
/// @dev THE ALGORITHM AND THE LAYOUT ARE OPENZEPPELIN'S, LINE FOR LINE. Reproduced rather
///      than reinvented, so a fork whose only difference is an absent overload can be diffed
///      against the original in one pass. DO NOT IMPROVE IT: if it ever diverges by anything
///      other than that overload, the reason belongs in this comment. The identical layout
///      also matters because `ChainRegistry` is a UUPS proxy whose storage outlives its
///      bytecode, so returning to `EnumerableSet` later is a source change with no migration.
///
/// @dev PLAIN `values()` NEVER NEEDED `Arrays`: it is a storage-to-memory copy the compiler
///      performs on the `return`. Only the paginated form needed slicing.
library Bytes32Set {
    struct Set {
        bytes32[] _values;
        /// The index of a value in `_values`, PLUS ONE. Zero means the value is absent,
        /// which is what makes `contains` a single read with no sentinel value to reserve.
        mapping(bytes32 value => uint256) _positions;
    }

    /// @notice Add a value. Returns false if it was already present.
    function add(Set storage self, bytes32 value) internal returns (bool) {
        if (contains(self, value)) return false;

        self._values.push(value);
        // Stored at `length - 1`, recorded as `length`, because zero is the absent marker.
        self._positions[value] = self._values.length;
        return true;
    }

    /// @notice Remove a value. Returns false if it was not present.
    ///
    /// @dev SWAP AND POP, SO REMOVAL IS O(1) AND REORDERS THE ARRAY. A removal moves the
    ///      last value into the hole, so `at(i)` is NOT stable across one. That is
    ///      OpenZeppelin's documented behaviour and already this registry's; anything
    ///      iterating by index across a removal has to re-read.
    function remove(Set storage self, bytes32 value) internal returns (bool) {
        uint256 position = self._positions[value];
        if (position == 0) return false;

        uint256 valueIndex = position - 1;
        uint256 lastIndex = self._values.length - 1;

        if (valueIndex != lastIndex) {
            bytes32 lastValue = self._values[lastIndex];
            // Move the last value into the hole, and follow it with its position.
            self._values[valueIndex] = lastValue;
            self._positions[lastValue] = position;
        }

        self._values.pop();
        delete self._positions[value];
        return true;
    }

    function contains(Set storage self, bytes32 value) internal view returns (bool) {
        return self._positions[value] != 0;
    }

    function length(Set storage self) internal view returns (uint256) {
        return self._values.length;
    }

    /// @notice The value at `index`. Order is not meaningful and not stable across a
    ///         removal; see `remove`.
    /// @dev Out of range panics on the array access, matching `EnumerableSet`.
    function at(Set storage self, uint256 index) internal view returns (bytes32) {
        return self._values[index];
    }

    /// @notice Every value, in the set's current internal order.
    function values(Set storage self) internal view returns (bytes32[] memory) {
        return self._values;
    }
}
