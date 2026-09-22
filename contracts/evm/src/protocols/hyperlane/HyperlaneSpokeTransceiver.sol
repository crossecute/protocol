// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";

/// @notice Transceiver on every non-home chain.
/// @dev Routing is three write-once values: `homeChainKey`, `homeRoute()`, `homeTransceiver()`
///      — no provider domain here, unlike Hyperlane's own `uint32`.
contract HyperlaneSpokeTransceiver is SpokeTransceiverBase {
    /// @param homeChainKey_ keccak256 of the home chain's ERC-7930 chain identifier.
    /// @param homeChainIdentifier_ That identifier itself; checked against `homeChainKey_`.
    /// @param homeTransceiver_ The hub, in this chain's address format. No setter.
    /// @dev Parity spoke: `addressesDiverge` is `false` by construction. A diverging chain
    ///      uses `HyperlaneZkSyncSpokeTransceiver`/`HyperlaneTronSpokeTransceiver` instead.
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_
    ) external initializer {
        __SpokeTransceiverBase_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            false
        );
    }

    /// @notice No gateway granted yet. See `HyperlaneHubTransceiver` for why no R3.3
    ///         exception is needed, provided `Router` is skipped.
}
