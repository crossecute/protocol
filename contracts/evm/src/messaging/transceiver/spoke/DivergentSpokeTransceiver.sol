// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {DivergentAccounts, ZkSyncAccounts, TronAccounts} from "src/messaging/transceiver/DivergentAccounts.sol";

/// @title DivergentSpokeTransceiver
/// @notice The spokes on zkSync Era and Tron. The derivation is `DivergentAccounts`'; these
///         only join it to `SpokeTransceiverBase`.
abstract contract DivergentSpokeTransceiver is SpokeTransceiverBase, DivergentAccounts {
    function __DivergentSpoke_init(bytes32 accountBytecodeHash_) internal onlyInitializing {
        __DivergentAccounts_init(accountBytecodeHash_);
    }
}

/// @title ZkSyncSpokeTransceiver
/// @notice A spoke on zkSync Era. See `ZkSyncAccounts`.
abstract contract ZkSyncSpokeTransceiver is DivergentSpokeTransceiver, ZkSyncAccounts {
    function predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        public
        view
        virtual
        override
        returns (address)
    {
        return _zkSyncAccount(accountSalt(owner, salt, homeChainKey));
    }

    function _deployAccount(bytes32 salt) internal virtual override returns (address) {
        return _zkSyncDeploy(salt);
    }
}

/// @title TronSpokeTransceiver
/// @notice A spoke on Tron. See `TronAccounts`.
abstract contract TronSpokeTransceiver is DivergentSpokeTransceiver, TronAccounts {
    function predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        public
        view
        virtual
        override
        returns (address)
    {
        return _tronAccount(accountSalt(owner, salt, homeChainKey));
    }
}
