// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {LzTransceiver} from "src/protocols/layerzero/LzTransceiver.sol";
import {LzZkSyncTransceiver} from "src/protocols/layerzero/LzDivergentTransceiver.sol";
import {LzReceiver} from "src/protocols/layerzero/LzReceiver.sol";
import {LzTransmitter} from "src/protocols/layerzero/LzTransmitter.sol";
import {check} from "script/deploy/CrossProxyDeploy.sol";
import {TransceiverDeployment, deployTransceiverProxy, checkGovernorHomeId} from "script/deploy/TransceiverDeploy.sol";

/// @notice LayerZero's contracts. OApp checks the endpoint itself, so no gateway role is granted.
library LzDeploy {
    function receiverImplementation(address endpoint) internal returns (address) {
        return address(new LzReceiver(endpoint));
    }

    function transmitterImplementation(address endpoint) internal returns (address) {
        return address(new LzTransmitter(endpoint));
    }

    function transceiverImplementation(address endpoint) internal returns (address) {
        return address(new LzTransceiver(endpoint));
    }

    function zkSyncTransceiverImplementation(address endpoint) internal returns (address) {
        return address(new LzZkSyncTransceiver(endpoint));
    }

    /// @param homeEid LayerZero's eid for the governor's home.
    /// @param homeDvn This chain's DVN for the home's pathway, or zero for LayerZero's defaults.
    function transceiver(TransceiverDeployment memory d, uint32 homeEid, address homeDvn) internal returns (address t) {
        t = deployTransceiverProxy(
            d, abi.encodeCall(LzTransceiver.initialize, (d.config, homeEid, homeDvn)), address(0)
        );
        _checkHome(t, d.config, homeEid, homeDvn);
    }

    function zkSyncTransceiver(
        TransceiverDeployment memory d,
        uint32 homeEid,
        address homeDvn,
        bytes32 accountBytecodeHash
    ) internal returns (address t) {
        t = deployTransceiverProxy(
            d,
            abi.encodeCall(LzZkSyncTransceiver.initialize, (d.config, homeEid, homeDvn, accountBytecodeHash)),
            address(0)
        );
        _checkHome(t, d.config, homeEid, homeDvn);
    }

    /// @dev LayerZero delivers only from a set peer, so where the registry resolves the home's
    ///      counterpart, the bootstrap that creates the owner needs that peer from birth.
    function _checkHome(address t, TransceiverConfig memory c, uint32 homeEid, address homeDvn) private view {
        checkGovernorHomeId(t, c, homeEid);
        check(LzTransceiver(payable(t)).dvnOf(homeEid) == homeDvn, "the governor home's DVN is the one named");
        bytes32 home = keccak256(c.governorHome);
        TransceiverBase tb = TransceiverBase(payable(t));
        if (homeEid == 0 || home == tb.localChainKey() || address(c.chainRegistry) == address(0)) return;
        bytes32 counterpart = bytes32(uint256(uint160(bytes20(tb.counterpartOn(home)))));
        check(IOAppCore(t).peers(homeEid) == counterpart, "the governor home's peer is its counterpart");
    }
}
