// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {WormholeTransceiver} from "src/protocols/wormhole/WormholeTransceiver.sol";
import {WormholeReceiver} from "src/protocols/wormhole/WormholeReceiver.sol";
import {WormholeTransmitter} from "src/protocols/wormhole/WormholeTransmitter.sol";
import {TransceiverDeployment, deployTransceiverProxy, checkGovernorHomeId} from "script/deploy/TransceiverDeploy.sol";

/// @notice Wormhole's contracts. The Core bridge holds the gateway role, though delivery
///         through `executeVAAv1` is permissionless.
library WormholeDeploy {
    struct Endpoints {
        address coreBridge;
        address executor;
    }

    function receiverImplementation(Endpoints memory e) internal returns (address) {
        return address(new WormholeReceiver(e.coreBridge));
    }

    function transmitterImplementation(Endpoints memory e) internal returns (address) {
        return address(new WormholeTransmitter(e.coreBridge, e.executor));
    }

    function transceiverImplementation(Endpoints memory e) internal returns (address) {
        return address(new WormholeTransceiver(e.coreBridge, e.executor));
    }

    /// @param homeChain Wormhole's chain id for the governor's home.
    function transceiver(TransceiverDeployment memory d, address coreBridge, uint16 homeChain)
        internal
        returns (address t)
    {
        t = deployTransceiverProxy(d, abi.encodeCall(WormholeTransceiver.initialize, (d.config, homeChain)), coreBridge);
        checkGovernorHomeId(t, d.config, homeChain);
    }
}
