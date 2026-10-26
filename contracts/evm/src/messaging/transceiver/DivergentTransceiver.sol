// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {TransceiverExtension} from "src/messaging/transceiver/TransceiverExtension.sol";
import {DivergentConduits, ZkSyncConduits, TronConduits} from "src/messaging/transceiver/DivergentConduits.sol";

/// @title DivergentTransceiver
/// @notice The combined transceiver on zkSync Era and Tron, whose conduit addresses differ
///         from Ethereum's CREATE2. The derivation is `DivergentConduits`'.
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
abstract contract DivergentTransceiver is TransceiverBase, DivergentConduits {
    /// @dev Sets the derivation inputs first: the extension derives the owner with them.
    function __DivergentTransceiver_init(TransceiverConfig memory c, bytes32 conduitBytecodeHash_)
        internal
        onlyInitializing
    {
        __DivergentConduits_init(conduitBytecodeHash_);
        __TransceiverBase_init(c, true);
    }

    function _parityAddress(bytes32 chainKey) internal view virtual override returns (address) {
        return _registryParityAddress(chainKey);
    }
}

/// @title ZkSyncTransceiver
/// @notice The combined transceiver on zkSync Era. See `ZkSyncConduits`.
abstract contract ZkSyncTransceiver is DivergentTransceiver, ZkSyncConduits {
    function _predictCrossConduit(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        virtual
        override
        returns (address)
    {
        return _zkSyncConduit(_conduitSalt(owner, salt, homeChainKey));
    }

    function _deployConduit(bytes32 salt) internal virtual override returns (address) {
        return _zkSyncDeploy(salt);
    }

    /// @dev EraVM cannot deploy raw initcode, and `_deployConduit` here reads none.
    function _storeCrossProxyInitCode() internal virtual override returns (address) {
        return address(0);
    }
}

/// @title TronTransceiver
/// @notice The combined transceiver on Tron. See `TronConduits`.
abstract contract TronTransceiver is DivergentTransceiver, TronConduits {
    function _predictCrossConduit(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        virtual
        override
        returns (address)
    {
        return _tronConduit(_conduitSalt(owner, salt, homeChainKey));
    }
}

/// @notice `TransceiverExtension` for a `DivergentTransceiver`.
abstract contract DivergentTransceiverExtension is TransceiverExtension, DivergentConduits {
    function _parityAddress(bytes32 chainKey) internal view virtual override returns (address) {
        return _registryParityAddress(chainKey);
    }
}

/// @notice The extension every `ZkSyncTransceiver` on a chain names.
contract ZkSyncTransceiverExtension is DivergentTransceiverExtension, ZkSyncConduits {
    function _predictCrossConduit(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        virtual
        override
        returns (address)
    {
        return _zkSyncConduit(_conduitSalt(owner, salt, homeChainKey));
    }
}

/// @notice The extension every `TronTransceiver` on a chain names.
contract TronTransceiverExtension is DivergentTransceiverExtension, TronConduits {
    function _predictCrossConduit(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        virtual
        override
        returns (address)
    {
        return _tronConduit(_conduitSalt(owner, salt, homeChainKey));
    }
}
