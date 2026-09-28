// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";

/// @notice C24's check over a `vm.startStateDiffRecording` window: no top-level call changes a
///         byte of `accounts`' storage that was already nonzero before it. Two fields sharing
///         storage fail as soon as the second is written. A call that restores what it changed,
///         like a reentrancy guard, changed nothing.
/// @dev Bytes rather than slots, because packed fields legitimately share a slot. Blind to a
///      collision inside one call, which is where an initializer writes its fields.
library SlotReuse {
    error SlotReused(address account, bytes32 slot, bytes32 previous, bytes32 next);

    function assertNone(Vm.AccountAccess[] memory accesses, address[] memory accounts) internal pure {
        uint64 top = type(uint64).max;
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].depth < top) top = accesses[i].depth;
        }
        uint256 from;
        for (uint256 i = 1; i <= accesses.length; ++i) {
            if (i == accesses.length || accesses[i].depth == top) {
                _assertCall(_writes(accesses, from, i, accounts));
                from = i;
            }
        }
    }

    /// @dev Within one call, a slot's first write carries its value before the call and its last
    ///      write the value after.
    function _assertCall(Vm.StorageAccess[] memory writes) private pure {
        for (uint256 i; i < writes.length; ++i) {
            if (_seenBefore(writes, i)) continue;
            bytes32 previous = writes[i].previousValue;
            bytes32 next = writes[i].newValue;
            for (uint256 j = i + 1; j < writes.length; ++j) {
                if (_sameSlot(writes[i], writes[j])) next = writes[j].newValue;
            }
            if (_overwrites(previous, next)) {
                revert SlotReused(writes[i].account, writes[i].slot, previous, next);
            }
        }
    }

    function _overwrites(bytes32 previous, bytes32 next) private pure returns (bool) {
        bytes32 changed = previous ^ next;
        for (uint256 i; i < 32; ++i) {
            if (changed[i] != 0 && previous[i] != 0) return true;
        }
        return false;
    }

    function _writes(Vm.AccountAccess[] memory accesses, uint256 from, uint256 to, address[] memory accounts)
        private
        pure
        returns (Vm.StorageAccess[] memory writes)
    {
        uint256 n;
        for (uint256 pass; pass < 2; ++pass) {
            if (pass == 1) writes = new Vm.StorageAccess[](n);
            n = 0;
            for (uint256 i = from; i < to; ++i) {
                Vm.StorageAccess[] memory s = accesses[i].storageAccesses;
                for (uint256 k; k < s.length; ++k) {
                    if (!s[k].isWrite || s[k].reverted || !_contains(accounts, s[k].account)) continue;
                    if (pass == 1) writes[n] = s[k];
                    ++n;
                }
            }
        }
    }

    function _seenBefore(Vm.StorageAccess[] memory writes, uint256 i) private pure returns (bool) {
        for (uint256 j; j < i; ++j) {
            if (_sameSlot(writes[i], writes[j])) return true;
        }
        return false;
    }

    function _sameSlot(Vm.StorageAccess memory a, Vm.StorageAccess memory b) private pure returns (bool) {
        return a.account == b.account && a.slot == b.slot;
    }

    function _contains(address[] memory accounts, address account) private pure returns (bool) {
        for (uint256 i; i < accounts.length; ++i) {
            if (accounts[i] == account) return true;
        }
        return false;
    }
}

/// @dev Two fields at one hand-picked slot, a field packed beside another, and a guard.
contract Collider {
    constructor() {
        assembly {
            sstore(1, 1)
        }
    }

    function setA(uint256 v) external {
        assembly {
            sstore(0x7201, v)
        }
    }

    function setB(uint256 v) external {
        assembly {
            sstore(0x7201, v)
        }
    }

    /// @dev The high byte of slot 2, leaving the low bytes as they were.
    function setPackedHigh(uint8 v) external {
        assembly {
            sstore(2, or(and(sload(2), not(shl(248, 0xff))), shl(248, v)))
        }
    }

    function setPackedLow(uint8 v) external {
        assembly {
            sstore(2, or(and(sload(2), not(0xff)), v))
        }
    }

    function guarded() external {
        assembly {
            sstore(1, 2)
            sstore(1, 1)
        }
    }
}

contract SlotReuseTest is Test {
    Collider c = new Collider();

    function check(Vm.AccountAccess[] memory accesses) external view {
        address[] memory accounts = new address[](1);
        accounts[0] = address(c);
        SlotReuse.assertNone(accesses, accounts);
    }

    function test_aSecondFieldInTheSameSlotIsCaught() public {
        vm.startStateDiffRecording();
        c.setA(1);
        c.setB(2);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        vm.expectRevert(
            abi.encodeWithSelector(SlotReuse.SlotReused.selector, address(c), bytes32(uint256(0x7201)), 1, 2)
        );
        this.check(accesses);
    }

    function test_packedFieldsAreNotACollision() public {
        vm.startStateDiffRecording();
        c.setPackedHigh(1);
        c.setPackedLow(2);
        this.check(vm.stopAndReturnStateDiff());
    }

    function test_aRestoredSlotIsNotAChange() public {
        vm.startStateDiffRecording();
        c.guarded();
        c.guarded();
        this.check(vm.stopAndReturnStateDiff());
    }
}
