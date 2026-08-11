// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";

/// @notice The per-user account on every chain that is not the home chain.
///
/// @dev THE GATEWAY SEAM IS UNANSWERED UNTIL A BINDING EXISTS, so this receiver accepts
///      nothing. There is no LayerZero gateway behind it yet, and a base that guessed an
///      address would be worse than one that refuses. A real binding answers here in one
///      line, exactly as `LzTransmitter` answers `_owner`.
contract LzReceiver is ReceiverBase {
    function _isAuthorizedGateway(address) internal pure override returns (bool) {
        return false;
    }
}
