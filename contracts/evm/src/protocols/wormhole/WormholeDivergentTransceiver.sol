// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {WormholeTransceiverBase} from "src/protocols/wormhole/WormholeTransceiver.sol";
import {TransceiverConfig} from "src/messaging/transceiver/SymmetricTransceiverBase.sol";
import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {
    DivergentSymmetricTransceiver,
    ZkSyncSymmetricTransceiver,
    TronSymmetricTransceiver
} from "src/messaging/transceiver/DivergentSymmetricTransceiver.sol";

/// @dev The overrides below only name both bases, as Solidity requires where each supplies an
///      implementation; `super` resolves by linearization to the one that does the work.

/// @notice `WormholeTransceiverBase` on zkSync Era: zkSync's address derivation and deployment.
contract WormholeZkSyncTransceiver is ZkSyncSymmetricTransceiver, WormholeTransceiverBase {
    constructor(address coreBridge_, address quoterRouter_, address quoter_)
        WormholeTransceiverBase(coreBridge_, quoterRouter_, quoter_)
    {}

    /// @param accountBytecodeHash_ Zksolc artifact hash for `CrossProxy`, not
    ///        `CROSS_PROXY_INIT_CODE_HASH` (solc's, meaningless on Era).
    function initialize(TransceiverConfig memory c, bytes32 accountBytecodeHash_) external initializer {
        __WormholeTransceiver_init();
        __DivergentSymmetric_init(c, accountBytecodeHash_);
    }

    function predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        public
        view
        override(TransceiverBase, ZkSyncSymmetricTransceiver)
        returns (address)
    {
        return super.predictCrossAccount(owner, salt, homeChainKey);
    }

    function _deployAccount(bytes32 salt)
        internal
        override(TransceiverBase, ZkSyncSymmetricTransceiver)
        returns (address)
    {
        return super._deployAccount(salt);
    }

    function _parityAddress(bytes32 chainKey)
        internal
        view
        override(HubTransceiverBase, DivergentSymmetricTransceiver)
        returns (address)
    {
        return super._parityAddress(chainKey);
    }
}

/// @notice `WormholeTransceiverBase` on Tron: Tron's address derivation only.
contract WormholeTronTransceiver is TronSymmetricTransceiver, WormholeTransceiverBase {
    constructor(address coreBridge_, address quoterRouter_, address quoter_)
        WormholeTransceiverBase(coreBridge_, quoterRouter_, quoter_)
    {}

    /// @param accountBytecodeHash_ Tron-solc's `CrossProxy` initcode hash, not solc's.
    function initialize(TransceiverConfig memory c, bytes32 accountBytecodeHash_) external initializer {
        __WormholeTransceiver_init();
        __DivergentSymmetric_init(c, accountBytecodeHash_);
    }

    function predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        public
        view
        override(TransceiverBase, TronSymmetricTransceiver)
        returns (address)
    {
        return super.predictCrossAccount(owner, salt, homeChainKey);
    }

    function _parityAddress(bytes32 chainKey)
        internal
        view
        override(HubTransceiverBase, DivergentSymmetricTransceiver)
        returns (address)
    {
        return super._parityAddress(chainKey);
    }
}
