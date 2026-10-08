// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
import {providerIdOf} from "src/protocols/ProviderChainId.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Per-user transmitter, created by `TransceiverBase.createTransmitter`.
/// @dev Sender-only: no `ccipReceive` inherited or implemented, so R3.1 is answered by
///      absence rather than a guard.
contract CcipTransmitter is OwnableTransmitter {
    /// @notice CCIP Router on this chain. Set on the implementation; safe because the
    ///         implementation address lives in the proxy's ERC-1967 slot, not its
    ///         initcode, so this never moves a derived account address.
    address public immutable router;

    constructor(address router_) {
        if (router_ == address(0)) revert ProviderAddress.ZeroEndpoint();
        router = router_;
    }

    /// @dev `recipient`'s address half is used, unlike LayerZero's peer table: CCIP has no
    ///      provider-side peer concept, so `EVM2AnyMessage.receiver` names the destination
    ///      exactly the way `_recipientOn` already resolved it. `feeToken` is always
    ///      `address(0)` (native payment; P8).
    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint64 setter
        uint64 selector = uint64(providerIdOf(transceiver, recipient));
        CcipMessage.send(router, selector, recipient, payload, attributes, value, _defaultGas(payload));
        return bytes32(0);
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint64 setter
        uint64 selector = uint64(providerIdOf(transceiver, recipient));
        return CcipMessage.quote(router, selector, recipient, payload, attributes, _defaultGas(payload));
    }

    bytes4 public constant CCIP_EXTRA_ARGS_ATTRIBUTE = CcipMessage.EXTRA_ARGS_ATTRIBUTE;

    function supportsAttribute(bytes4 selector) external pure override returns (bool) {
        return selector == CCIP_EXTRA_ARGS_ATTRIBUTE;
    }

    /// @notice No gateway is granted here: the Router holds `GATEWAY_ROLE` on the
    ///         transceiver and receivers; the transmitter has no inbound entry point (R3.1).
}
