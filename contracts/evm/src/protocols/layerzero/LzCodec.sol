// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title LzCodec
/// @notice LayerZero's own name for a chain, in the shape `ChainRegistry` stores.
///
/// @dev THE ROUTE IS `bytes`, NOT `uint32`, AND IS ENCODED WITH `abi.encode`. The
///      registry is provider-agnostic by design (it holds a Hyperlane uint32 domain, a
///      Wormhole uint16, and a CCIP uint64 selector in the same slot), so the width has
///      to be carried by the value rather than by the mapping's type. Fixed-width
///      `abi.encode` means a value configured at the wrong width fails loudly in
///      `abi.decode` here, where `encodePacked` would silently reinterpret it and route
///      to whatever chain the truncated bits happen to name.
library LzCodec {
    /// @notice LayerZero V2 endpoint id for Ethereum mainnet.
    /// @dev A CONVENIENCE, NOT A SETTING. The home chain is an initialization parameter,
    ///      so nothing here is wired to Ethereum; this is the value a deployment anchoring
    ///      there would pass.
    uint32 internal constant ETHEREUM_EID = 30101;

    function encodeEid(uint32 eid) internal pure returns (bytes memory) {
        return abi.encode(eid);
    }

    function decodeEid(bytes memory route) internal pure returns (uint32) {
        return abi.decode(route, (uint32));
    }
}
