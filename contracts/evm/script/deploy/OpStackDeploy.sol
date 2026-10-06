// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OpStackTransceiver} from "src/protocols/op-stack/OpStackTransceiver.sol";
import {OpStackReceiver} from "src/protocols/op-stack/OpStackReceiver.sol";
import {OpStackTransmitter} from "src/protocols/op-stack/OpStackTransmitter.sol";
import {IOpStackMessengerSource} from "src/protocols/op-stack/OpStackTransmitter.sol";
import {check} from "script/deploy/CrossProxyDeploy.sol";
import {TransceiverDeployment, deployTransceiverProxy} from "script/deploy/TransceiverDeploy.sol";

/// @notice OP Stack's contracts. The messenger is the gateway, and the chain it pairs with is
///         an implementation immutable, so a transceiver serves exactly one pair.
library OpStackDeploy {
    function receiverImplementation(address messenger) internal returns (address) {
        return address(new OpStackReceiver(messenger));
    }

    /// @dev Reads its messenger from the transceiver that creates it.
    function transmitterImplementation() internal returns (address) {
        return address(new OpStackTransmitter());
    }

    function transceiverImplementation(address messenger, bytes32 pairedChainKey) internal returns (address) {
        return address(new OpStackTransceiver(messenger, pairedChainKey));
    }

    function transceiver(TransceiverDeployment memory d, address messenger, bytes32 pairedChainKey)
        internal
        returns (address t)
    {
        t = deployTransceiverProxy(d, abi.encodeCall(OpStackTransceiver.initialize, (d.config)), messenger);
        check(IOpStackMessengerSource(t).messenger() == messenger, "messenger");
        check(IOpStackMessengerSource(t).messengerChainKey() == pairedChainKey, "paired chain");
    }
}
