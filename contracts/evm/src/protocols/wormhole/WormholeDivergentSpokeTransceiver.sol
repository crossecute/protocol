// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ZkSyncSpokeTransceiver,
    TronSpokeTransceiver
} from "src/messaging/transceiver/spoke/DivergentSpokeTransceiver.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {WormholeSpokeBase} from "src/protocols/wormhole/WormholeSpokeTransceiver.sol";

/// @dev The overrides below only name both bases, as Solidity requires where each supplies an
///      implementation; `super` resolves by linearization to the one that does the work.

/// @notice `WormholeSpokeBase` on zkSync Era: zkSync's address derivation and deployment.
contract WormholeZkSyncSpokeTransceiver is ZkSyncSpokeTransceiver, WormholeSpokeBase {
    constructor(address coreBridge_, address quoterRouter_, address quoter_)
        WormholeSpokeBase(coreBridge_, quoterRouter_, quoter_)
    {}

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
        uint16 homeWormholeChain_
    ) external initializer {
        __WormholeSpoke_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            treasuryOwner_,
            treasurySalt_,
            true,
            homeWormholeChain_
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

/// @notice `WormholeSpokeBase` on Tron: Tron's address derivation only.
contract WormholeTronSpokeTransceiver is TronSpokeTransceiver, WormholeSpokeBase {
    constructor(address coreBridge_, address quoterRouter_, address quoter_)
        WormholeSpokeBase(coreBridge_, quoterRouter_, quoter_)
    {}

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
        uint16 homeWormholeChain_
    ) external initializer {
        __WormholeSpoke_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            treasuryOwner_,
            treasurySalt_,
            true,
            homeWormholeChain_
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
