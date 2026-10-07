// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OpStackInteropTransceiver} from "src/protocols/op-stack/OpStackInteropTransceiver.sol";
import {OpStackInteropReceiver} from "src/protocols/op-stack/OpStackInteropReceiver.sol";
import {OpStackInteropTransmitter} from "src/protocols/op-stack/OpStackInteropTransmitter.sol";
import {OpStackInteropMessage} from "src/protocols/op-stack/OpStackInteropMessage.sol";
import {VM, check} from "script/deploy/CrossProxyDeploy.sol";
import {ChainConfig, ChainEntry, Derivation} from "script/deploy/ChainConfig.sol";
import {TransceiverDeployment, deployTransceiverProxy} from "script/deploy/TransceiverDeploy.sol";

/// @notice `op-stack-l2-l2`'s contracts. The messenger is a predeploy, so nothing provider-specific
///         is an argument, and it is the gateway.
library OpStackInteropDeploy {
    function receiverImplementation() internal returns (address) {
        return address(new OpStackInteropReceiver());
    }

    function transmitterImplementation() internal returns (address) {
        return address(new OpStackInteropTransmitter());
    }

    function transceiverImplementation() internal returns (address) {
        return address(new OpStackInteropTransceiver());
    }

    /// @dev Refused where interop is not live: the transceiver's only gateway would be an
    ///      empty address, and its receivers' too.
    function transceiver(TransceiverDeployment memory d) internal returns (address) {
        check(OpStackInteropMessage.MESSENGER.code.length != 0, "the L2ToL2CrossDomainMessenger is live here");
        return deployTransceiverProxy(
            d, abi.encodeCall(OpStackInteropTransceiver.initialize, (d.config)), OpStackInteropMessage.MESSENGER
        );
    }
}

/// @notice Reads `deploy/providers/op-stack-l2-l2.toml`, checking that every listed chain is a
///         configured parity chain.
library OpStackInteropConfig {
    function isMember(string memory dir, ChainEntry[] memory cs, ChainEntry memory chain)
        internal
        view
        returns (bool member)
    {
        string memory toml = ChainConfig.read(string.concat(dir, "/providers/op-stack-l2-l2.toml"));
        string[] memory names = VM.parseTomlStringArray(toml, ".chains");
        for (uint256 i; i < names.length; ++i) {
            check(ChainConfig.hasChainNamed(cs, names[i]), "interop chains are keyed by chains.toml names");
            check(_derivation(cs, names[i]) == Derivation.Parity, "an interop chain is a parity chain");
            if (keccak256(bytes(names[i])) == keccak256(bytes(chain.name))) member = true;
        }
    }

    function _derivation(ChainEntry[] memory cs, string memory name) private pure returns (Derivation) {
        for (uint256 i; i < cs.length; ++i) {
            if (keccak256(bytes(cs[i].name)) == keccak256(bytes(name))) return cs[i].derivation;
        }
        return Derivation.Other;
    }
}
