// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ZkSyncSpokeTransceiver, TronSpokeTransceiver} from
    "src/messaging/transceiver/spoke/DivergentSpokeTransceiver.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {LzSpokeBase} from "src/protocols/layerzero/LzSpokeTransceiver.sol";

/// @dev The overrides below only name both bases, as Solidity requires where each supplies an
///      implementation; `super` resolves to `LzSpokeBase` for LayerZero's functions and
///      to the zkSync/Tron base for address derivation.

/// @notice `LzSpokeBase` on zkSync Era: zkSync's address derivation and deployment.
contract LzZkSyncSpokeTransceiver is ZkSyncSpokeTransceiver, LzSpokeBase {
    constructor(address _endpoint) LzSpokeBase(_endpoint) {}

    /// @param accountBytecodeHash_ ZKSOLC artifact hash for `CrossProxy`, not
    ///        `CROSS_PROXY_INIT_CODE_HASH` (solc's, meaningless on Era).
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bytes32 accountBytecodeHash_,
        uint32 homeEid_
    ) external initializer {
        __LzSpoke_init(
            gateways, receiverImplementation_, homeChainKey_, homeChainIdentifier_, homeTransceiver_, true, homeEid_
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

    function predictCrossAccount(address owner, bytes32 salt)
        public
        view
        override(TransceiverBase, ZkSyncSpokeTransceiver)
        returns (address)
    {
        return super.predictCrossAccount(owner, salt);
    }

    function _deployAccount(bytes32 salt) internal override(TransceiverBase, ZkSyncSpokeTransceiver) returns (address) {
        return super._deployAccount(salt);
    }

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override(OutboundBase, LzSpokeBase)
        returns (bytes32)
    {
        return super._sendMessage(recipient, payload, attributes, value);
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override(OutboundBase, LzSpokeBase)
        returns (uint256)
    {
        return super._quoteMessage(recipient, payload, attributes);
    }

    function _accountInitializer(address owner, bytes32 salt, Call[] memory calls)
        internal
        view
        override(SpokeTransceiverBase, LzSpokeBase)
        returns (bytes memory)
    {
        return super._accountInitializer(owner, salt, calls);
    }
}

/// @notice `LzSpokeBase` on Tron: Tron's address derivation only.
contract LzTronSpokeTransceiver is TronSpokeTransceiver, LzSpokeBase {
    constructor(address _endpoint) LzSpokeBase(_endpoint) {}

    /// @param accountBytecodeHash_ TRON-solc's `CrossProxy` initcode hash, not solc's.
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bytes32 accountBytecodeHash_,
        uint32 homeEid_
    ) external initializer {
        __LzSpoke_init(
            gateways, receiverImplementation_, homeChainKey_, homeChainIdentifier_, homeTransceiver_, true, homeEid_
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

    function predictCrossAccount(address owner, bytes32 salt)
        public
        view
        override(TransceiverBase, TronSpokeTransceiver)
        returns (address)
    {
        return super.predictCrossAccount(owner, salt);
    }

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override(OutboundBase, LzSpokeBase)
        returns (bytes32)
    {
        return super._sendMessage(recipient, payload, attributes, value);
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override(OutboundBase, LzSpokeBase)
        returns (uint256)
    {
        return super._quoteMessage(recipient, payload, attributes);
    }

    function _accountInitializer(address owner, bytes32 salt, Call[] memory calls)
        internal
        view
        override(SpokeTransceiverBase, LzSpokeBase)
        returns (bytes memory)
    {
        return super._accountInitializer(owner, salt, calls);
    }
}
