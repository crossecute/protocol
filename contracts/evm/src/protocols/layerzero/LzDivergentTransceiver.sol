// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LzTransceiverBase} from "src/protocols/layerzero/LzTransceiver.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {
    DivergentTransceiver,
    ZkSyncTransceiver,
    TronTransceiver
} from "src/messaging/transceiver/DivergentTransceiver.sol";
import {Call} from "src/messaging/Call.sol";

/// @dev The overrides below only name both bases, as Solidity requires where each supplies an
///      implementation; `super` resolves by linearization to the one that does the work.

/// @notice `LzTransceiverBase` on zkSync Era: zkSync's address derivation and deployment.
contract LzZkSyncTransceiver is ZkSyncTransceiver, LzTransceiverBase {
    constructor(address _endpoint) LzTransceiverBase(_endpoint) {}

    /// @param accountBytecodeHash_ Zksolc artifact hash for `CrossProxy`, not
    ///        `CROSS_PROXY_INIT_CODE_HASH` (solc's, meaningless on Era).
    function initialize(TransceiverConfig memory c, uint32 governorHomeEid, bytes32 accountBytecodeHash_)
        external
        initializer
    {
        __LzTransceiver_init(c, governorHomeEid);
        __DivergentTransceiver_init(c, accountBytecodeHash_);
        _initGovernorHomePeer(c, governorHomeEid);
    }

    function predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        public
        view
        override(TransceiverBase, ZkSyncTransceiver)
        returns (address)
    {
        return super.predictCrossAccount(owner, salt, homeChainKey);
    }

    function _deployAccount(bytes32 salt) internal override(TransceiverBase, ZkSyncTransceiver) returns (address) {
        return super._deployAccount(salt);
    }

    function _parityAddress(bytes32 chainKey)
        internal
        view
        override(TransceiverBase, DivergentTransceiver)
        returns (address)
    {
        return super._parityAddress(chainKey);
    }

    function _accountInitializer(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls
    ) internal view override(TransceiverBase, LzTransceiverBase) returns (bytes memory) {
        return super._accountInitializer(owner, salt, homeChainKey, sourceTransmitter, calls);
    }
}

/// @notice `LzTransceiverBase` on Tron: Tron's address derivation only.
contract LzTronTransceiver is TronTransceiver, LzTransceiverBase {
    constructor(address _endpoint) LzTransceiverBase(_endpoint) {}

    /// @param accountBytecodeHash_ Tron-solc's `CrossProxy` initcode hash, not solc's.
    function initialize(TransceiverConfig memory c, uint32 governorHomeEid, bytes32 accountBytecodeHash_)
        external
        initializer
    {
        __LzTransceiver_init(c, governorHomeEid);
        __DivergentTransceiver_init(c, accountBytecodeHash_);
        _initGovernorHomePeer(c, governorHomeEid);
    }

    function predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        public
        view
        override(TransceiverBase, TronTransceiver)
        returns (address)
    {
        return super.predictCrossAccount(owner, salt, homeChainKey);
    }

    function _parityAddress(bytes32 chainKey)
        internal
        view
        override(TransceiverBase, DivergentTransceiver)
        returns (address)
    {
        return super._parityAddress(chainKey);
    }

    function _accountInitializer(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls
    ) internal view override(TransceiverBase, LzTransceiverBase) returns (bytes memory) {
        return super._accountInitializer(owner, salt, homeChainKey, sourceTransmitter, calls);
    }
}
