// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HyperlaneTransceiverBase} from "src/protocols/hyperlane/HyperlaneTransceiver.sol";
import {TransceiverConfig, TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {
    DivergentTransceiver,
    ZkSyncTransceiver,
    TronTransceiver
} from "src/messaging/transceiver/DivergentTransceiver.sol";

/// @dev The overrides below only name both bases, as Solidity requires where each supplies an
///      implementation; `super` resolves by linearization to the one that does the work.

/// @notice `HyperlaneTransceiverBase` on zkSync Era: zkSync's address derivation and deployment.
contract HyperlaneZkSyncTransceiver is ZkSyncTransceiver, HyperlaneTransceiverBase {
    constructor(address mailbox_) HyperlaneTransceiverBase(mailbox_) {}

    /// @param accountBytecodeHash_ Zksolc artifact hash for `CrossProxy`, not
    ///        `CROSS_PROXY_INIT_CODE_HASH` (solc's, meaningless on Era).
    function initialize(TransceiverConfig memory c, bytes32 accountBytecodeHash_) external initializer {
        __HyperlaneTransceiver_init();
        __DivergentTransceiver_init(c, accountBytecodeHash_);
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
}

/// @notice `HyperlaneTransceiverBase` on Tron: Tron's address derivation only.
contract HyperlaneTronTransceiver is TronTransceiver, HyperlaneTransceiverBase {
    constructor(address mailbox_) HyperlaneTransceiverBase(mailbox_) {}

    /// @param accountBytecodeHash_ Tron-solc's `CrossProxy` initcode hash, not solc's.
    function initialize(TransceiverConfig memory c, bytes32 accountBytecodeHash_) external initializer {
        __HyperlaneTransceiver_init();
        __DivergentTransceiver_init(c, accountBytecodeHash_);
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
}
