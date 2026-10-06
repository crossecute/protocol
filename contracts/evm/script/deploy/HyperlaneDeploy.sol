// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {HyperlaneTransceiver} from "src/protocols/hyperlane/HyperlaneTransceiver.sol";
import {HyperlaneZkSyncTransceiver} from "src/protocols/hyperlane/HyperlaneDivergentTransceiver.sol";
import {HyperlaneReceiver} from "src/protocols/hyperlane/HyperlaneReceiver.sol";
import {HyperlaneTransmitter} from "src/protocols/hyperlane/HyperlaneTransmitter.sol";
import {TransceiverDeployment, deployTransceiverProxy, checkGovernorHomeId} from "script/deploy/TransceiverDeploy.sol";

/// @notice Hyperlane's contracts. The Mailbox is the gateway.
library HyperlaneDeploy {
    function receiverImplementation(address mailbox) internal returns (address) {
        return address(new HyperlaneReceiver(mailbox));
    }

    function transmitterImplementation(address mailbox) internal returns (address) {
        return address(new HyperlaneTransmitter(mailbox));
    }

    function transceiverImplementation(address mailbox) internal returns (address) {
        return address(new HyperlaneTransceiver(mailbox));
    }

    function zkSyncTransceiverImplementation(address mailbox) internal returns (address) {
        return address(new HyperlaneZkSyncTransceiver(mailbox));
    }

    /// @param homeDomain Hyperlane's domain for the governor's home.
    function transceiver(TransceiverDeployment memory d, address mailbox, uint32 homeDomain)
        internal
        returns (address t)
    {
        t = deployTransceiverProxy(d, abi.encodeCall(HyperlaneTransceiver.initialize, (d.config, homeDomain)), mailbox);
        checkGovernorHomeId(t, d.config, homeDomain);
    }

    function zkSyncTransceiver(
        TransceiverDeployment memory d,
        address mailbox,
        uint32 homeDomain,
        bytes32 accountBytecodeHash
    ) internal returns (address t) {
        t = deployTransceiverProxy(
            d,
            abi.encodeCall(HyperlaneZkSyncTransceiver.initialize, (d.config, homeDomain, accountBytecodeHash)),
            mailbox
        );
        checkGovernorHomeId(t, d.config, homeDomain);
    }
}
