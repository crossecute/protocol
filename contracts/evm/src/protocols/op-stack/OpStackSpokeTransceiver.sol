// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";

/// @notice Transceiver on the OP Stack chain that is not the home chain.
/// @dev Routing is three write-once values: `homeChainKey`, `homeRoute()`, `homeTransceiver()`
///      — no provider chain id needed (see `OpStackHubTransceiver` for why `ProviderChainId`
///      doesn't apply here).
///
/// @dev Always the parity spoke, no divergent variant: an OP Stack chain runs standard
///      `op-geth` and Ethereum's own CREATE2 formula, unlike zkSync/Tron.
contract OpStackSpokeTransceiver is SpokeTransceiverBase {
    /// @param homeChainKey_ keccak256 of the home chain's ERC-7930 chain identifier.
    /// @param homeChainIdentifier_ That identifier itself; checked against `homeChainKey_`.
    /// @param homeTransceiver_ The hub, in this chain's address format. No setter.
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

    /// @notice No gateway granted yet. A real binding grants `GATEWAY_ROLE` to the L2
    ///         `CrossDomainMessenger` predeploy (constant address on every OP Stack chain).
    /// @dev Same sharp edge as `OpStackReceiver`, for bootstrap: the inbound entry point must
    ///      call `ICrossDomainMessenger(msg.sender).xDomainMessageSender()` itself and treat
    ///      that as the origin — never a value decoded out of the delivered message.
}
