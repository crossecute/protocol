// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CcipTransceiverBase} from "src/protocols/ccip/CcipTransceiver.sol";
import {TransceiverConfig, TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    DivergentTransceiver,
    ZkSyncTransceiver,
    TronTransceiver
} from "src/messaging/transceiver/DivergentTransceiver.sol";

/// @dev The overrides below only name both bases, as Solidity requires where each supplies an
///      implementation; `super` resolves by linearization to the one that does the work.

/// @notice `CcipTransceiverBase` on zkSync Era: zkSync's address derivation and deployment.
contract CcipZkSyncTransceiver is ZkSyncTransceiver, CcipTransceiverBase {
    constructor(address router_) CcipTransceiverBase(router_) {}

    /// @param accountBytecodeHash_ Zksolc artifact hash for `CrossProxy`, not
    ///        `CROSS_PROXY_INIT_CODE_HASH`, which Era's deployer does not key by.
    function initialize(TransceiverConfig memory c, uint64 governorHomeSelector, bytes32 accountBytecodeHash_)
        external
        initializer
    {
        __CcipTransceiver_init(c, governorHomeSelector);
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

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable, CcipTransceiverBase)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

/// @notice `CcipTransceiverBase` on Tron: Tron's address derivation only.
contract CcipTronTransceiver is TronTransceiver, CcipTransceiverBase {
    constructor(address router_) CcipTransceiverBase(router_) {}

    /// @param accountBytecodeHash_ Tron-solc's `CrossProxy` initcode hash, not solc's.
    function initialize(TransceiverConfig memory c, uint64 governorHomeSelector, bytes32 accountBytecodeHash_)
        external
        initializer
    {
        __CcipTransceiver_init(c, governorHomeSelector);
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

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable, CcipTransceiverBase)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
