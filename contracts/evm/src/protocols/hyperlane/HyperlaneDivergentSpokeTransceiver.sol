// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ZkSyncSpokeTransceiver,
    TronSpokeTransceiver
} from "src/messaging/transceiver/spoke/DivergentSpokeTransceiver.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {HyperlaneSpokeBase} from "src/protocols/hyperlane/HyperlaneSpokeTransceiver.sol";

/// @dev The overrides below only name both bases, as Solidity requires where each supplies an
///      implementation; `super` resolves by linearization to the one that does the work.

/// @notice `HyperlaneSpokeBase` on zkSync Era: zkSync's address derivation and deployment.
contract HyperlaneZkSyncSpokeTransceiver is ZkSyncSpokeTransceiver, HyperlaneSpokeBase {
    constructor(address mailbox_) HyperlaneSpokeBase(mailbox_) {}

    /// @param accountBytecodeHash_ Zksolc artifact hash for `CrossProxy`, not
    ///        `CROSS_PROXY_INIT_CODE_HASH` (solc's, meaningless on Era).
    function initialize(
        address[] memory gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes memory homeChainIdentifier_,
        bytes memory homeTransceiver_,
        address treasury_,
        bytes32 accountBytecodeHash_,
        uint32 homeDomain_
    ) external initializer {
        __HyperlaneSpoke_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            treasury_,
            true,
            homeDomain_
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
}

/// @notice `HyperlaneSpokeBase` on Tron: Tron's address derivation only.
contract HyperlaneTronSpokeTransceiver is TronSpokeTransceiver, HyperlaneSpokeBase {
    constructor(address mailbox_) HyperlaneSpokeBase(mailbox_) {}

    /// @param accountBytecodeHash_ Tron-solc's `CrossProxy` initcode hash, not solc's.
    function initialize(
        address[] memory gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes memory homeChainIdentifier_,
        bytes memory homeTransceiver_,
        address treasury_,
        bytes32 accountBytecodeHash_,
        uint32 homeDomain_
    ) external initializer {
        __HyperlaneSpoke_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            treasury_,
            true,
            homeDomain_
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
}
