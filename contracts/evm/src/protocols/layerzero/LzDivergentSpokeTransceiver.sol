// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    ZkSyncSpokeTransceiver,
    TronSpokeTransceiver
} from "src/messaging/transceiver/spoke/DivergentSpokeTransceiver.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {LzSpokeBase} from "src/protocols/layerzero/LzSpokeTransceiver.sol";

/// @dev The overrides below only name both bases, as Solidity requires where each supplies an
///      implementation; `super` resolves by linearization to the one that does the work.

/// @notice `LzSpokeBase` on zkSync Era: zkSync's address derivation and deployment.
contract LzZkSyncSpokeTransceiver is ZkSyncSpokeTransceiver, LzSpokeBase {
    constructor(address _endpoint) LzSpokeBase(_endpoint) {}

    /// @param accountBytecodeHash_ Zksolc artifact hash for `CrossProxy`, not
    ///        `CROSS_PROXY_INIT_CODE_HASH` (solc's, meaningless on Era).
    function initialize(
        address[] memory gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes memory homeChainIdentifier_,
        bytes memory homeTransceiver_,
        address treasuryOwner_,
        bytes32 treasurySalt_,
        bytes32 accountBytecodeHash_,
        uint32 homeEid_
    ) external initializer {
        __LzSpoke_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            treasuryOwner_,
            treasurySalt_,
            true,
            homeEid_
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

    function predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        public
        view
        override(TransceiverBase, ZkSyncSpokeTransceiver)
        returns (address)
    {
        return super.predictCrossAccount(owner, salt, homeChainKey);
    }

    function _deployAccount(bytes32 salt) internal override(TransceiverBase, ZkSyncSpokeTransceiver) returns (address) {
        return super._deployAccount(salt);
    }

    function _accountInitializer(address owner, bytes32 salt, address sourceTransmitter, Call[] memory calls)
        internal
        view
        override(SpokeTransceiverBase, LzSpokeBase)
        returns (bytes memory)
    {
        return super._accountInitializer(owner, salt, sourceTransmitter, calls);
    }
}

/// @notice `LzSpokeBase` on Tron: Tron's address derivation only.
contract LzTronSpokeTransceiver is TronSpokeTransceiver, LzSpokeBase {
    constructor(address _endpoint) LzSpokeBase(_endpoint) {}

    /// @param accountBytecodeHash_ Tron-solc's `CrossProxy` initcode hash, not solc's.
    function initialize(
        address[] memory gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes memory homeChainIdentifier_,
        bytes memory homeTransceiver_,
        address treasuryOwner_,
        bytes32 treasurySalt_,
        bytes32 accountBytecodeHash_,
        uint32 homeEid_
    ) external initializer {
        __LzSpoke_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            treasuryOwner_,
            treasurySalt_,
            true,
            homeEid_
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

    function predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        public
        view
        override(TransceiverBase, TronSpokeTransceiver)
        returns (address)
    {
        return super.predictCrossAccount(owner, salt, homeChainKey);
    }

    function _accountInitializer(address owner, bytes32 salt, address sourceTransmitter, Call[] memory calls)
        internal
        view
        override(SpokeTransceiverBase, LzSpokeBase)
        returns (bytes memory)
    {
        return super._accountInitializer(owner, salt, sourceTransmitter, calls);
    }
}
