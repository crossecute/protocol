// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {TransceiverExtension} from "src/messaging/transceiver/TransceiverExtension.sol";
import {DivergentAccounts, ZkSyncAccounts, TronAccounts} from "src/messaging/transceiver/DivergentAccounts.sol";

/// @title DivergentTransceiver
/// @notice The combined transceiver on zkSync Era and Tron, whose account addresses differ
///         from Ethereum's CREATE2. The derivation is `DivergentAccounts`'.
///
/// @dev Every receiver created here is reported to its home, which cannot derive it, so
///      `addressesDiverge` is set here rather than taken from the caller.
///
/// @dev This transceiver does not sit at its provider's address on other chains, so its default
///      counterpart on a `Predetermined` chain is derived from the registry's record of the
///      provider's deployment, not taken from `address(this)` or typed in.
///
/// @dev Each variant below has an extension variant beside it that overrides the same seams with
///      the same helper; `TransceiverBase.__TransceiverBase_init` refuses a pair whose owner
///      derivations differ.
abstract contract DivergentTransceiver is TransceiverBase, DivergentAccounts {
    /// @dev Sets the derivation inputs first: the extension derives the owner with them.
    function __DivergentTransceiver_init(TransceiverConfig memory c, bytes32 accountBytecodeHash_)
        internal
        onlyInitializing
    {
        __DivergentAccounts_init(accountBytecodeHash_);
        __TransceiverBase_init(c, true);
    }

    function _parityAddress(bytes32 chainKey) internal view virtual override returns (address) {
        return _registryParityAddress(chainKey);
    }
}

/// @title ZkSyncTransceiver
/// @notice The combined transceiver on zkSync Era. See `ZkSyncAccounts`.
abstract contract ZkSyncTransceiver is DivergentTransceiver, ZkSyncAccounts {
    function _predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        virtual
        override
        returns (address)
    {
        return _zkSyncAccount(_accountSalt(owner, salt, homeChainKey));
    }

    function _deployAccount(bytes32 salt) internal virtual override returns (address) {
        return _zkSyncDeploy(salt);
    }
}

/// @title TronTransceiver
/// @notice The combined transceiver on Tron. See `TronAccounts`.
abstract contract TronTransceiver is DivergentTransceiver, TronAccounts {
    function _predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        virtual
        override
        returns (address)
    {
        return _tronAccount(_accountSalt(owner, salt, homeChainKey));
    }
}

/// @notice `TransceiverExtension` for a `DivergentTransceiver`.
abstract contract DivergentTransceiverExtension is TransceiverExtension, DivergentAccounts {
    function _parityAddress(bytes32 chainKey) internal view virtual override returns (address) {
        return _registryParityAddress(chainKey);
    }
}

/// @notice The extension every `ZkSyncTransceiver` on a chain names.
contract ZkSyncTransceiverExtension is DivergentTransceiverExtension, ZkSyncAccounts {
    function _predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        virtual
        override
        returns (address)
    {
        return _zkSyncAccount(_accountSalt(owner, salt, homeChainKey));
    }
}

/// @notice The extension every `TronTransceiver` on a chain names.
contract TronTransceiverExtension is DivergentTransceiverExtension, TronAccounts {
    function _predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        virtual
        override
        returns (address)
    {
        return _tronAccount(_accountSalt(owner, salt, homeChainKey));
    }
}
