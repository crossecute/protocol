// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CcipPolicy} from "src/protocols/ccip/CcipPolicy.sol";
import {ProviderReceiver} from "src/protocols/ProviderReceiver.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {RolesEnumerable} from "src/messaging/Roles.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Per-user conduit on a non-home chain.
contract CcipReceiver is ProviderReceiver, CCIPReceiver, CcipPolicy {
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

    /// @dev Delivery accepts only (homeOrigin, sourceTransmitter), so a policy under any other key
    ///      would be stored but never read. A change arrives as a self-call delivered under the
    ///      current policy, so a policy whose verifiers stop attesting also blocks its own reset.
    function _authorizeCcipPolicyChange(uint64 source, address sender) internal view override {
        if (!isAuthorizedCaller(msg.sender)) revert NotSourceTransmitter();
        if (bytes32(uint256(source)) != homeOrigin || !isSourceTransmitter(sender)) revert InvalidCcipPolicy();
    }

    function getCCVsAndFinalityConfig(uint64 source, bytes calldata sender)
        public
        view
        override(CCIPReceiver, CcipPolicy)
        returns (
            address[] memory requiredCCVs,
            address[] memory optionalCCVs,
            uint8 optionalThreshold,
            bytes4 allowedFinalityConfig
        )
    {
        return CcipPolicy.getCCVsAndFinalityConfig(source, sender);
    }

    function supportsInterface(bytes4 interfaceId) public view override(RolesEnumerable, CCIPReceiver) returns (bool) {
        return CCIPReceiver.supportsInterface(interfaceId) || RolesEnumerable.supportsInterface(interfaceId);
    }
}
