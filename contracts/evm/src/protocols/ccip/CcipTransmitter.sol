// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
import {providerIdOf} from "src/protocols/ProviderHubTransceiver.sol";

/// @notice Per-user transmitter, created by `HubTransceiverBase.createTransmitter`.
/// @dev Sender-only: no `ccipReceive` inherited or implemented, so R3.1 is answered by
///      absence rather than a guard.
contract CcipTransmitter is OwnableTransmitter {
    /// @notice CCIP Router on this chain. Set on the implementation; safe because the
    ///         implementation address lives in the proxy's ERC-1967 slot, not its
    ///         initcode, so this never moves a derived account address.
    address public immutable router;

    constructor(address router_) {
        router = router_;
    }

    /// @dev `recipient`'s address half IS used, unlike LayerZero's peer table: CCIP has no
    ///      provider-side peer concept, so `EVM2AnyMessage.receiver` names the destination
    ///      exactly the way `_recipientOn` already resolved it. `feeToken` is always
    ///      `address(0)` (native payment; P8).
    function _sendMessage(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value
    ) internal override returns (bytes32 sendId) {
        CcipMessage.send(router, uint64(providerIdOf(transceiver, recipient)), recipient, payload, attributes, value);
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        return CcipMessage.quote(router, uint64(providerIdOf(transceiver, recipient)), recipient, payload, attributes);
    }

    bytes4 public constant CCIP_EXTRA_ARGS_ATTRIBUTE = CcipMessage.EXTRA_ARGS_ATTRIBUTE;

    function supportsAttribute(bytes4 selector) external pure override returns (bool) {
        return selector == CCIP_EXTRA_ARGS_ATTRIBUTE;
    }

    /// @notice No gateway is granted here: the Router holds `GATEWAY_ROLE` on the hub,
    ///         spokes, and receivers; the transmitter has no inbound entry point (R3.1).
}
