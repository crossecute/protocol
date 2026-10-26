// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ProviderReceiver} from "src/protocols/ProviderReceiver.sol";
import {OpStackInteropMessage} from "src/protocols/op-stack/OpStackInteropMessage.sol";
import {IOpStackRecipient} from "src/protocols/op-stack/OpStackMessage.sol";

/// @notice Per-user conduit on a non-home chain, for `op-stack-l2-l2`.
/// @dev The origin is the source chain id the messenger reports, which must be the home's.
contract OpStackInteropReceiver is ProviderReceiver, IOpStackRecipient {
    function _providerGateway() internal pure override returns (address) {
        return OpStackInteropMessage.MESSENGER;
    }

    /// @dev The sender is `crossDomainMessageSender()`, never anything in `payload`. No R3.3
    ///      exception; `_onMessageFrom` is the only sender check.
    function receiveOpStackMessage(bytes calldata payload) external override onlyRole(GATEWAY_ROLE) {
        (address sender, uint256 source) = OpStackInteropMessage.context();
        _onMessageFrom(bytes32(source), sender, payload);
    }
}
