// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {OpStackInteropMessage} from "src/protocols/op-stack/OpStackInteropMessage.sol";
import {IOpStackRecipient} from "src/protocols/op-stack/OpStackMessage.sol";

/// @notice Superchain interop on `TransceiverBase`: the `op-stack-l2-l2` provider, between OP
///         Stack chains. Ethereum to an OP Stack chain is `op-stack-l1-l2`.
///
/// @dev One messenger, the predeploy, reaches every chain in this chain's dependency set and
///      names a destination by its chain id, which the recipient carries, so there is no
///      provider id table. A route is configured only for a chain in the dependency set, and
///      every send and quote, here and on the transmitters, reverts `NoRouteFor` anywhere
///      else (`OpStackInteropMessage`).
///
/// @dev A delivery's origin is the source chain the messenger reports, never anything in the
///      message, and it must be routed here.
///
/// @dev No zkSync or Tron variant: an OP Stack chain uses Ethereum's CREATE2 formula.
contract OpStackInteropTransceiver is TransceiverBase, IOpStackRecipient {
    constructor(address extension_) TransceiverBase(extension_) {}

    /// @dev Grants `GATEWAY_ROLE` to the messenger: `receiveOpStackMessage` is gated on it.
    function initialize(TransceiverConfig memory c) external initializer {
        _grantInitialRole(GATEWAY_ROLE, OpStackInteropMessage.MESSENGER);
        __TransceiverBase_init(c);
    }

    /* ===================================== sending ===================================== */

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32)
    {
        return OpStackInteropMessage.send(address(this), recipient, payload, attributes, value);
    }

    /// @dev Zero: see `OpStackInteropMessage`.
    function _quoteMessage(bytes memory recipient, bytes memory, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        return OpStackInteropMessage.quote(address(this), recipient, attributes);
    }

    /* ==================================== receiving ==================================== */

    function receiveOpStackMessage(bytes calldata payload) external override onlyRole(GATEWAY_ROLE) {
        (address sender, uint256 source) = OpStackInteropMessage.context();
        _onInbound(routeFor(ChainKey.forEvm(source)), abi.encodePacked(sender), payload);
    }

    /// @inheritdoc TransceiverBase
    /// @dev A receiver names its home by the chain id the messenger reports as the source.
    function _accountInitializer(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls
    ) internal view override returns (bytes memory) {
        if (homeChainKey == localChainKey) {
            return super._accountInitializer(owner, salt, homeChainKey, sourceTransmitter, calls);
        }
        bytes32 home = bytes32(Erc7930.evmChainId(Erc7930.parseStrict(routeFor(homeChainKey))));
        return abi.encodeCall(IReceiverInit.initialize, (sourceTransmitter, home, calls));
    }
}
