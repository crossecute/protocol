// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ZkSyncSpokeTransceiver,
    TronSpokeTransceiver
} from "src/messaging/transceiver/spoke/DivergentSpokeTransceiver.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {CcipSpokeBase} from "src/protocols/ccip/CcipSpokeTransceiver.sol";

/// @dev The overrides below only name both bases, as Solidity requires where each supplies an
///      implementation; `super` resolves by linearization to the one that does the work.

/// @notice `CcipSpokeBase` on zkSync Era: zkSync's address derivation and deployment.
contract CcipZkSyncSpokeTransceiver is ZkSyncSpokeTransceiver, CcipSpokeBase {
    constructor(address router_) CcipSpokeBase(router_) {}

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
        uint64 homeSelector_
    ) external initializer {
        __CcipSpoke_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            treasury_,
            true,
            homeSelector_
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

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlEnumerableUpgradeable, CcipSpokeBase)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

/// @notice `CcipSpokeBase` on Tron: Tron's address derivation only.
contract CcipTronSpokeTransceiver is TronSpokeTransceiver, CcipSpokeBase {
    constructor(address router_) CcipSpokeBase(router_) {}

    /// @param accountBytecodeHash_ Tron-solc's `CrossProxy` initcode hash, not solc's.
    function initialize(
        address[] memory gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes memory homeChainIdentifier_,
        bytes memory homeTransceiver_,
        address treasury_,
        bytes32 accountBytecodeHash_,
        uint64 homeSelector_
    ) external initializer {
        __CcipSpoke_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            treasury_,
            true,
            homeSelector_
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

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlEnumerableUpgradeable, CcipSpokeBase)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
