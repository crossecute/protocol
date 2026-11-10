// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice How a signature-enabled transmitter finds its owner Safe's transaction guard: read the
///         guard slot on every `sendMessage` instead of pinning an address.
library GuardDiscovery {
    /// @dev Safe's `GuardManager.GUARD_STORAGE_SLOT`, `keccak256("guard_manager.guard.address")`.
    uint256 internal constant GUARD_STORAGE_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;

    error MalformedGuardSlot(address safe);
    error NoGuard(address safe);

    /// @dev Reverts unless `safe` answers `getStorageAt(slot, 1)` with exactly one word holding an
    ///      address with code. There is no fallback to an unsigned send.
    function transactionGuard(address safe) internal view returns (address guard) {
        (bool success, bytes memory reply) =
            safe.staticcall(abi.encodeWithSignature("getStorageAt(uint256,uint256)", GUARD_STORAGE_SLOT, 1));
        require(success && reply.length == 96, MalformedGuardSlot(safe));
        (uint256 offset, uint256 length, uint256 word) = abi.decode(reply, (uint256, uint256, uint256));
        require(offset == 32 && length == 32 && word >> 160 == 0, MalformedGuardSlot(safe));
        // forge-lint: disable-next-line(unsafe-typecast) upper bits checked zero above
        guard = address(uint160(word));
        require(guard.code.length != 0, NoGuard(safe));
    }
}
