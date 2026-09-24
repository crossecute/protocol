// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {IWormholeReceiver} from "@wormhole-sdk/interfaces/IWormholeRelayer.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";

/// @notice Per-user account on a non-home chain.
/// @dev No replay guard of its own: the Relayer refuses a second delivery of a hash that
///      already succeeded (`deliverySuccessBlock`). A reverting call here does not revert the
///      delivery transaction; the Relayer records `RECEIVER_FAILURE` and the delivery can be
///      retried.
contract WormholeReceiver is ReceiverBase, IWormholeReceiver {
    /// @notice Wormhole Relayer on this chain. Set on the implementation; safe because the
    ///         implementation address lives in the proxy's ERC-1967 slot, not its initcode,
    ///         so this never moves a derived account address.
    address public immutable relayer;

    constructor(address relayer_) {
        relayer = relayer_;
    }

    /// @dev `grantRole` is `onlyInitializing`, so this initializer is the only window the
    ///      Relayer's gateway grant ever gets.
    function initialize(address sourceTransmitter_, Call[] calldata calls) external override initializer {
        grantRole(GATEWAY_ROLE, relayer);
        __ReceiverBase_init(sourceTransmitter_, calls);
    }

    /// @dev The Relayer checks the delivery VAA's guardian signatures and that its emitter is
    ///      a registered Relayer, nothing about the source-chain sender, so
    ///      `isSourceTransmitter` is the only sender check: no R3.3 exception. Narrows via
    ///      `isSourceTransmitter` rather than `_authenticateSender` for the same reason as
    ///      `CcipReceiver`.
    function receiveWormholeMessages(
        bytes calldata payload,
        bytes[] calldata additionalMessages,
        bytes32 sourceAddress,
        uint16, /* sourceChain */
        bytes32 /* deliveryHash */
    ) external payable override onlyRole(GATEWAY_ROLE) {
        WormholeMessage.requireNoAdditionalMessages(additionalMessages);
        if (!isSourceTransmitter(WormholeMessage.senderOf(sourceAddress))) revert NotSourceTransmitter();
        _onMessage(payload);
    }
}
