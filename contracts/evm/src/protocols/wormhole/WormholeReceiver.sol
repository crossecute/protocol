// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {IVaaV1Receiver} from "@wormhole-sdk/interfaces/IExecutor.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";

/// @notice Per-user account on a non-home chain.
/// @dev `GATEWAY_ROLE` is held by the Core bridge, which never calls in: `executeVAAv1` is
///      permissionless and checks the role's membership instead of `msg.sender`, so
///      `revokeGateway(coreBridge)` still disconnects Wormhole. See `WormholeMessage.verify`.
contract WormholeReceiver is ReceiverBase, IVaaV1Receiver {
    /// @notice Core bridge on this chain. Set on the implementation; safe because the
    ///         implementation address lives in the proxy's ERC-1967 slot, not its initcode,
    ///         so this never moves a derived account address.
    address public immutable coreBridge;

    constructor(address coreBridge_) {
        coreBridge = coreBridge_;
    }

    /// @dev `grantRole` is `onlyInitializing`, so this initializer is the only window the
    ///      Core bridge's gateway grant ever gets.
    function initialize(address sourceTransmitter_, Call[] calldata calls) external override initializer {
        grantRole(GATEWAY_ROLE, coreBridge);
        __ReceiverBase_init(sourceTransmitter_, calls);
    }

    /// @dev Guardian signatures authenticate the emitter; `_onMessageFrom` is the only sender
    ///      check, so no R3.3 exception.
    function executeVAAv1(bytes calldata multiSigVaa) external payable override {
        (, address emitter, bytes calldata payload) =
            WormholeMessage.verify(coreBridge, hasRole(GATEWAY_ROLE, coreBridge), multiSigVaa);
        _onMessageFrom(emitter, payload);
    }

    function vaaConsumed(bytes32 vaaHash) external view returns (bool) {
        return WormholeMessage.consumed(vaaHash);
    }
}
