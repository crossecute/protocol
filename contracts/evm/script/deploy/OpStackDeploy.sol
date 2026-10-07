// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OpStackTransceiver} from "src/protocols/op-stack/OpStackTransceiver.sol";
import {OpStackReceiver} from "src/protocols/op-stack/OpStackReceiver.sol";
import {OpStackTransmitter} from "src/protocols/op-stack/OpStackTransmitter.sol";
import {TransceiverDeployment, deployTransceiverProxy, checkGovernorHomeId} from "script/deploy/TransceiverDeploy.sol";
import {VM, check} from "script/deploy/CrossProxyDeploy.sol";
import {ChainConfig, ChainEntry} from "script/deploy/ChainConfig.sol";

/// @notice `op-stack-l1-l2`'s contracts. Each chain's messenger is its provider id, so nothing
///         provider-specific is an implementation immutable and no gateway role is granted:
///         the transceiver's table is the gate.
library OpStackDeploy {
    function receiverImplementation() internal returns (address) {
        return address(new OpStackReceiver());
    }

    function transmitterImplementation() internal returns (address) {
        return address(new OpStackTransmitter());
    }

    function transceiverImplementation() internal returns (address) {
        return address(new OpStackTransceiver());
    }

    /// @param homeMessenger The messenger on this chain that reaches the governor's home.
    function transceiver(TransceiverDeployment memory d, address homeMessenger) internal returns (address t) {
        t = deployTransceiverProxy(
            d, abi.encodeCall(OpStackTransceiver.initialize, (d.config, homeMessenger)), address(0)
        );
        checkGovernorHomeId(t, d.config, uint160(homeMessenger));
    }
}

/// @notice Reads `deploy/providers/op-stack-l1-l2.toml`, checking it as it goes: the L1 and every
///         key name a configured chain, and every messenger is nonzero and distinct.
library OpStackConfig {
    /// @notice The messenger on `local` that reaches `remote`, or zero where none does: the L1
    ///         reaches each listed OP Stack chain through its own messenger, and each reaches
    ///         only the L1, through the predeploy.
    function messenger(string memory dir, ChainEntry[] memory cs, ChainEntry memory local, ChainEntry memory remote)
        internal
        view
        returns (address)
    {
        string memory toml = ChainConfig.read(string.concat(dir, "/providers/op-stack-l1-l2.toml"));
        string memory l1 = VM.parseTomlString(toml, ".l1");
        check(ChainConfig.hasChainNamed(cs, l1), "the OP Stack L1 is a configured chain");
        address l2Messenger = VM.parseTomlAddress(toml, ".l2_messenger");
        check(l2Messenger != address(0), "the L2 messenger is nonzero");

        string[] memory l2s = VM.parseTomlKeys(toml, ".l1_messengers");
        address[] memory l1Messengers = new address[](l2s.length);
        address found;
        bool localIsL2;
        for (uint256 i; i < l2s.length; ++i) {
            check(ChainConfig.hasChainNamed(cs, l2s[i]), "OP Stack chains are keyed by chains.toml names");
            check(!_eq(l2s[i], l1), "the L1 is not an OP Stack chain of itself");
            l1Messengers[i] = VM.parseTomlAddress(toml, string.concat(".l1_messengers.", l2s[i]));
            check(l1Messengers[i] != address(0) && l1Messengers[i] != l2Messenger, "an L1 messenger is its own");
            for (uint256 j; j < i; ++j) {
                check(l1Messengers[j] != l1Messengers[i], "each OP Stack chain has its own L1 messenger");
            }
            if (_eq(local.name, l1) && _eq(remote.name, l2s[i])) found = l1Messengers[i];
            if (_eq(local.name, l2s[i])) localIsL2 = true;
        }
        if (localIsL2 && _eq(remote.name, l1)) found = l2Messenger;
        return found;
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
