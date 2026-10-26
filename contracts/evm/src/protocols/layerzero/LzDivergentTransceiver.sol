// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LzTransceiverBase} from "src/protocols/layerzero/LzTransceiver.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {TransceiverCore} from "src/messaging/transceiver/TransceiverCore.sol";
import {
    DivergentTransceiver,
    ZkSyncTransceiver,
    TronTransceiver
} from "src/messaging/transceiver/DivergentTransceiver.sol";
import {Call} from "src/messaging/Call.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @dev The overrides below only name both bases, as Solidity requires where each supplies an
///      implementation; `super` resolves by linearization to the one that does the work.

/// @notice `LzTransceiverBase` on zkSync Era: zkSync's address derivation and deployment.
contract LzZkSyncTransceiver is ZkSyncTransceiver, LzTransceiverBase {
    constructor(address _endpoint, address extension_) LzTransceiverBase(_endpoint, extension_) {}

    /// @param conduitBytecodeHash_ Zksolc artifact hash for `CrossProxy`, not
    ///        `CROSS_PROXY_INIT_CODE_HASH`, which Era's deployer does not key by.
    function initialize(
        TransceiverConfig memory c,
        uint32 governorHomeEid,
        address governorHomeDvn,
        bytes32 conduitBytecodeHash_
    ) external initializer {
        __LzTransceiver_init(c, governorHomeEid, governorHomeDvn);
        __DivergentTransceiver_init(c, conduitBytecodeHash_);
        _initGovernorHomePeer(c, governorHomeEid);
    }

    function _predictCrossConduit(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        override(TransceiverCore, ZkSyncTransceiver)
        returns (address)
    {
        return super._predictCrossConduit(owner, salt, homeChainKey);
    }

    function _deployConduit(bytes32 salt) internal override(TransceiverBase, ZkSyncTransceiver) returns (address) {
        return super._deployConduit(salt);
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

    function _conduitInitializer(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls
    ) internal view override(TransceiverBase, LzTransceiverBase) returns (bytes memory) {
        return super._conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls);
    }

    function _checkOwner() internal view override(OwnableUpgradeable, LzTransceiverBase) {
        super._checkOwner();
    }
}

/// @notice `LzTransceiverBase` on Tron: Tron's address derivation only.
contract LzTronTransceiver is TronTransceiver, LzTransceiverBase {
    constructor(address _endpoint, address extension_) LzTransceiverBase(_endpoint, extension_) {}

    /// @param conduitBytecodeHash_ Tron-solc's `CrossProxy` initcode hash, not solc's.
    function initialize(
        TransceiverConfig memory c,
        uint32 governorHomeEid,
        address governorHomeDvn,
        bytes32 conduitBytecodeHash_
    ) external initializer {
        __LzTransceiver_init(c, governorHomeEid, governorHomeDvn);
        __DivergentTransceiver_init(c, conduitBytecodeHash_);
        _initGovernorHomePeer(c, governorHomeEid);
    }

    function _predictCrossConduit(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        override(TransceiverCore, TronTransceiver)
        returns (address)
    {
        return super._predictCrossConduit(owner, salt, homeChainKey);
    }

    function _parityAddress(bytes32 chainKey)
        internal
        view
        override(TransceiverCore, DivergentTransceiver)
        returns (address)
    {
        return super._parityAddress(chainKey);
    }

    function _conduitInitializer(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls
    ) internal view override(TransceiverBase, LzTransceiverBase) returns (bytes memory) {
        return super._conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls);
    }

    function _checkOwner() internal view override(OwnableUpgradeable, LzTransceiverBase) {
        super._checkOwner();
    }
}
