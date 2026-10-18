// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ProviderReceiver} from "src/protocols/ProviderReceiver.sol";
import {IVaaV1Receiver} from "@wormhole-sdk/interfaces/IExecutor.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Per-user account on a non-home chain.
/// @dev `GATEWAY_ROLE` is held by the Core bridge, which never calls in: `executeVAAv1` is
///      permissionless and checks the role's membership instead of `msg.sender`, so
///      `revokeGateway(coreBridge)` still disconnects Wormhole. See `WormholeMessage.verify`.
contract WormholeReceiver is ProviderReceiver, IVaaV1Receiver {
    /// @notice Core bridge on this chain. Set on the implementation; safe because the
    ///         implementation address lives in the proxy's ERC-1967 slot, not its initcode,
    ///         so this never moves a derived account address.
    address public immutable coreBridge;

    constructor(address coreBridge_) {
        if (coreBridge_ == address(0)) revert ProviderAddress.ZeroEndpoint();
        coreBridge = coreBridge_;
    }

    function _providerGateway() internal view override returns (address) {
        return coreBridge;
    }

    /// @dev Guardian signatures authenticate the emitter and its chain; `_onMessageFrom` is the
    ///      only check of either, so no R3.3 exception.
    function executeVAAv1(bytes calldata multiSigVaa) external payable override {
        (uint16 emitterChain, address emitter, bytes calldata payload) =
            WormholeMessage.verify(coreBridge, hasRole(GATEWAY_ROLE, coreBridge), multiSigVaa);
        _onMessageFrom(bytes32(uint256(emitterChain)), emitter, payload);
    }

    function vaaConsumed(bytes32 vaaHash) external view returns (bool) {
        return WormholeMessage.consumed(vaaHash);
    }
}
