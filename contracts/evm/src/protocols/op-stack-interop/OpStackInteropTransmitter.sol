// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {OpStackInteropMessage} from "src/protocols/op-stack-interop/OpStackInteropMessage.sol";

/// @notice Per-user transmitter for `op-stack-l2-l2`, created by
///         `TransceiverBase.createTransmitter`.
/// @dev Sender-only: no `receiveInteropMessage`, so R3.1 is answered by absence rather than a
///      guard.
contract OpStackInteropTransmitter is OwnableTransmitter {
    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        return OpStackInteropMessage.send(transceiver, recipient, payload, attributes, value);
    }

    /// @dev Zero: see `OpStackInteropMessage`.
    function _quoteMessage(bytes memory recipient, bytes memory, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        return OpStackInteropMessage.quote(transceiver, recipient, attributes);
    }

    /// @dev None: the relay's sender chooses its gas.
    function supportsAttribute(bytes4) external pure override returns (bool) {
        return false;
    }
}
