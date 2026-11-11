// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICrossecuteGuard} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {GuardDiscovery} from "@crossecute/safe-guard/GuardDiscovery.sol";

/// @notice Whether a conduit owner gets signed mode at creation (#108).
library SignedMode {
    // Safe's StorageAccessible.getStorageAt(uint256,uint256)
    bytes4 private constant GET_STORAGE_AT = 0x5624b25b;
    // ERC-165 supportsInterface(bytes4)
    bytes4 private constant SUPPORTS_INTERFACE = 0x01ffc9a7;

    /// @notice True only if `owner` answers its transaction guard slot with a contract that
    ///         affirms `ICrossecuteGuard` through ERC-165. Any failure along the way is false.
    /// @dev Unlike `GuardDiscovery.transactionGuard`, never reverts: an EOA, a non-Safe or a Safe
    ///      without a compatible guard creates a plain conduit.
    function isSigned(address owner) internal view returns (bool) {
        (bool ok, bytes memory reply) =
            owner.staticcall(abi.encodeWithSelector(GET_STORAGE_AT, GuardDiscovery.GUARD_STORAGE_SLOT, 1));
        if (!ok || reply.length != 96) return false;
        (uint256 offset, uint256 length, uint256 word) = abi.decode(reply, (uint256, uint256, uint256));
        if (offset != 32 || length != 32 || word >> 160 != 0) return false;
        // forge-lint: disable-next-line(unsafe-typecast) upper bits checked zero above
        address guard = address(uint160(word));
        if (guard.code.length == 0) return false;

        (ok, reply) = guard.staticcall(abi.encodeWithSelector(SUPPORTS_INTERFACE, type(ICrossecuteGuard).interfaceId));
        return ok && reply.length == 32 && abi.decode(reply, (uint256)) == 1;
    }
}
