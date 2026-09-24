// SPDX-License-Identifier: MIT OR Apache-2.0

// Vendored, unmodified, from hyperlane-xyz/hyperlane-monorepo @ 983831f6
// (solidity/contracts/libs/TypeCasts.sol).
// MIT OR Apache-2.0, like the rest of its source repo. No OpenZeppelin imports, unlike
// MailboxClient/Router. See docs/provider-research.md#5-hyperlane-as-a-native-binding.

pragma solidity >=0.6.11;

library TypeCasts {
    // alignment preserving cast
    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    // alignment preserving cast
    function bytes32ToAddress(bytes32 _buf) internal pure returns (address) {
        require(
            uint256(_buf) <= uint256(type(uint160).max),
            "TypeCasts: bytes32ToAddress overflow"
        );
        return address(uint160(uint256(_buf)));
    }
}
