// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ProviderReceiver} from "src/protocols/ProviderReceiver.sol";
import {IAny2EVMMessageReceiver} from "@ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@ccip/libraries/Client.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Per-user conduit on a non-home chain.
/// @dev Implements `IAny2EVMMessageReceiver.ccipReceive` directly, gated `onlyRole(GATEWAY_ROLE)`,
///      rather than inheriting Chainlink's `CCIPReceiver`, whose `onlyRouter` restates the role
///      and which checks no sender.
contract CcipReceiver is ProviderReceiver, IAny2EVMMessageReceiver {
    /// @notice CCIP Router on this chain. Set on the implementation; safe because the
    ///         implementation address lives in the proxy's ERC-1967 slot, not its
    ///         initcode, so this never moves a derived conduit address.
    address public immutable router;

    constructor(address router_) {
        if (router_ == address(0)) revert ProviderAddress.ZeroEndpoint();
        router = router_;
    }

    function _providerGateway() internal view override returns (address) {
        return router;
    }

    /// @dev CCIP's off-ramp asserts nothing about the source-chain sender
    ///      (`docs/provider-research.md#4-ccip-as-a-native-binding`), so `_onMessageFrom` is the
    ///      only origin and sender check: no R3.3 exception.
    function ccipReceive(Client.Any2EVMMessage calldata message) external onlyRole(GATEWAY_ROLE) {
        _onMessageFrom(bytes32(uint256(message.sourceChainSelector)), CcipMessage.sender(message), message.data);
    }

    /// @notice Declares support for `IAny2EVMMessageReceiver` and `IERC165`.
    /// @dev CCIP's off-ramp checks this before calling `ccipReceive`, and answering false makes
    ///      it mark the message executed without ever delivering it.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
