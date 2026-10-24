// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HyperlaneTransceiverBase} from "src/protocols/hyperlane/HyperlaneTransceiver.sol";
import {TransceiverConfig, TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {TransceiverCore} from "src/messaging/transceiver/TransceiverCore.sol";
import {ProviderTransceiver} from "src/protocols/ProviderTransceiver.sol";
import {Call} from "src/messaging/Call.sol";
import {
    DivergentTransceiver,
    ZkSyncTransceiver,
    TronTransceiver
} from "src/messaging/transceiver/DivergentTransceiver.sol";

/// @dev The overrides below only name both bases, as Solidity requires where each supplies an
///      implementation; `super` resolves by linearization to the one that does the work.

/// @notice `HyperlaneTransceiverBase` on zkSync Era: zkSync's address derivation and deployment.
contract HyperlaneZkSyncTransceiver is ZkSyncTransceiver, HyperlaneTransceiverBase {
    constructor(address mailbox_, address extension_) HyperlaneTransceiverBase(mailbox_, extension_) {}

    /// @param accountBytecodeHash_ Zksolc artifact hash for `CrossProxy`, not
    ///        `CROSS_PROXY_INIT_CODE_HASH`, which Era's deployer does not key by.
    function initialize(TransceiverConfig memory c, uint32 governorHomeDomain, bytes32 accountBytecodeHash_)
        external
        initializer
    {
        __HyperlaneTransceiver_init(c, governorHomeDomain);
        __DivergentTransceiver_init(c, accountBytecodeHash_);
    }

    function _predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        override(TransceiverCore, ZkSyncTransceiver)
        returns (address)
    {
        return super._predictCrossAccount(owner, salt, homeChainKey);
    }

    function _deployAccount(bytes32 salt) internal override(TransceiverBase, ZkSyncTransceiver) returns (address) {
        return super._deployAccount(salt);
    }

    function _storeCrossProxyInitCode() internal override(TransceiverBase, ZkSyncTransceiver) returns (address) {
        return super._storeCrossProxyInitCode();
    }

    function _parityAddress(bytes32 chainKey)
        internal
        view
        override(TransceiverCore, DivergentTransceiver)
        returns (address)
    {
        return super._parityAddress(chainKey);
    }

    function _accountInitializer(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls,
        bytes memory bindingData
    ) internal view override(TransceiverBase, ProviderTransceiver) returns (bytes memory) {
        return super._accountInitializer(owner, salt, homeChainKey, sourceTransmitter, calls, bindingData);
    }
}

/// @notice `HyperlaneTransceiverBase` on Tron: Tron's address derivation only.
contract HyperlaneTronTransceiver is TronTransceiver, HyperlaneTransceiverBase {
    constructor(address mailbox_, address extension_) HyperlaneTransceiverBase(mailbox_, extension_) {}

    /// @param accountBytecodeHash_ Tron-solc's `CrossProxy` initcode hash, not solc's.
    function initialize(TransceiverConfig memory c, uint32 governorHomeDomain, bytes32 accountBytecodeHash_)
        external
        initializer
    {
        __HyperlaneTransceiver_init(c, governorHomeDomain);
        __DivergentTransceiver_init(c, accountBytecodeHash_);
    }

    function _predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        override(TransceiverCore, TronTransceiver)
        returns (address)
    {
        return super._predictCrossAccount(owner, salt, homeChainKey);
    }

    function _parityAddress(bytes32 chainKey)
        internal
        view
        override(TransceiverCore, DivergentTransceiver)
        returns (address)
    {
        return super._parityAddress(chainKey);
    }

    function _accountInitializer(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls,
        bytes memory bindingData
    ) internal view override(TransceiverBase, ProviderTransceiver) returns (bytes memory) {
        return super._accountInitializer(owner, salt, homeChainKey, sourceTransmitter, calls, bindingData);
    }
}
