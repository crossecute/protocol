// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CcipTransceiver} from "src/protocols/ccip/CcipTransceiver.sol";
import {CcipZkSyncTransceiver} from "src/protocols/ccip/CcipDivergentTransceiver.sol";
import {CcipReceiver} from "src/protocols/ccip/CcipReceiver.sol";
import {CcipTransmitter} from "src/protocols/ccip/CcipTransmitter.sol";
import {TransceiverDeployment, deployTransceiverProxy, checkGovernorHomeId} from "script/deploy/TransceiverDeploy.sol";

/// @notice CCIP's contracts. The router is the gateway.
library CcipDeploy {
    function receiverImplementation(address router) internal returns (address) {
        return address(new CcipReceiver(router));
    }

    function transmitterImplementation(address router) internal returns (address) {
        return address(new CcipTransmitter(router));
    }

    function transceiverImplementation(address router) internal returns (address) {
        return address(new CcipTransceiver(router));
    }

    function zkSyncTransceiverImplementation(address router) internal returns (address) {
        return address(new CcipZkSyncTransceiver(router));
    }

    /// @param homeSelector CCIP's chain selector for the governor's home.
    function transceiver(TransceiverDeployment memory d, address router, uint64 homeSelector)
        internal
        returns (address t)
    {
        t = deployTransceiverProxy(d, abi.encodeCall(CcipTransceiver.initialize, (d.config, homeSelector)), router);
        checkGovernorHomeId(t, d.config, homeSelector);
    }

    function zkSyncTransceiver(
        TransceiverDeployment memory d,
        address router,
        uint64 homeSelector,
        bytes32 accountBytecodeHash
    ) internal returns (address t) {
        t = deployTransceiverProxy(
            d, abi.encodeCall(CcipZkSyncTransceiver.initialize, (d.config, homeSelector, accountBytecodeHash)), router
        );
        checkGovernorHomeId(t, d.config, homeSelector);
    }
}
