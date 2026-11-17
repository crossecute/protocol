// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ProviderReceiver} from "src/protocols/ProviderReceiver.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {RolesEnumerable} from "src/messaging/Roles.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Per-user conduit on a non-home chain.
contract CcipReceiver is ProviderReceiver, CCIPReceiver {
    constructor(address router_) CCIPReceiver(_checkedRouter(router_)) {}

    function _checkedRouter(address router_) private pure returns (address) {
        if (router_ == address(0)) revert ProviderAddress.ZeroEndpoint();
        return router_;
    }

    function router() public view returns (address) {
        return getRouter();
    }

    function _providerGateway() internal view override returns (address) {
        return getRouter();
    }

    /// @dev CCIP authenticates the router; the protocol also checks its gateway role and
    ///      the conduit's home and source transmitter before executing the payload.
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override onlyRole(GATEWAY_ROLE) {
        _onMessageFromMemory(
            bytes32(uint256(message.sourceChainSelector)), CcipMessage.sender(message.sender), message.data
        );
    }

    function supportsInterface(bytes4 interfaceId) public view override(RolesEnumerable, CCIPReceiver) returns (bool) {
        return CCIPReceiver.supportsInterface(interfaceId) || RolesEnumerable.supportsInterface(interfaceId);
    }
}
