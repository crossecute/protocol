// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CcipTransceiverBase} from "src/protocols/ccip/CcipTransceiver.sol";
import {TransceiverConfig, TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {TransceiverCore} from "src/messaging/transceiver/TransceiverCore.sol";
import {ProviderTransceiver} from "src/protocols/ProviderTransceiver.sol";
import {Call} from "src/messaging/Call.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ZkSyncTransceiver, TronTransceiver} from "src/messaging/transceiver/DivergentTransceiver.sol";

/// @dev The overrides below only name both bases, as Solidity requires where each supplies an
///      implementation; `super` resolves by linearization to the one that does the work.

/// @notice `CcipTransceiverBase` on zkSync Era: zkSync's address derivation and deployment.
contract CcipZkSyncTransceiver is ZkSyncTransceiver, CcipTransceiverBase {
    constructor(address router_, address extension_) CcipTransceiverBase(router_, extension_) {}

    /// @param conduitBytecodeHash_ Zksolc artifact hash for `Proxy`, not
    ///        `PROXY_INIT_CODE_HASH`, which Era's deployer does not key by.
    function initialize(TransceiverConfig memory c, uint64 governorHomeSelector, bytes32 conduitBytecodeHash_)
        external
        initializer
    {
        __CcipTransceiver_init(c, governorHomeSelector);
        __DivergentTransceiver_init(c, conduitBytecodeHash_);
    }

    function _conduitAt(bytes32 conduitSalt)
        internal
        view
        override(TransceiverCore, ZkSyncTransceiver)
        returns (address)
    {
        return super._conduitAt(conduitSalt);
    }

    function _deployConduit(bytes32 salt) internal override(TransceiverBase, ZkSyncTransceiver) returns (address) {
        return super._deployConduit(salt);
    }

    function _storeProxyInitCode() internal override(TransceiverBase, ZkSyncTransceiver) returns (address) {
        return super._storeProxyInitCode();
    }

    function _conduitInitializer(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls
    ) internal view override(TransceiverBase, ProviderTransceiver) returns (bytes memory) {
        return super._conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls);
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
    constructor(address router_, address extension_) CcipTransceiverBase(router_, extension_) {}

    /// @param conduitBytecodeHash_ Tron-solc's `Proxy` initcode hash, not solc's.
    function initialize(TransceiverConfig memory c, uint64 governorHomeSelector, bytes32 conduitBytecodeHash_)
        external
        initializer
    {
        __CcipTransceiver_init(c, governorHomeSelector);
        __DivergentTransceiver_init(c, conduitBytecodeHash_);
    }

    function _conduitAt(bytes32 conduitSalt)
        internal
        view
        override(TransceiverCore, TronTransceiver)
        returns (address)
    {
        return super._conduitAt(conduitSalt);
    }

    function _conduitInitializer(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls
    ) internal view override(TransceiverBase, ProviderTransceiver) returns (bytes memory) {
        return super._conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls);
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
