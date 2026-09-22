// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ZkSyncSpokeTransceiver, TronSpokeTransceiver} from
    "src/messaging/transceiver/spoke/DivergentSpokeTransceiver.sol";

/// @notice Spoke on a chain whose CREATE2 formula isn't Ethereum's: zkSync Era and Tron.
///         Protocol-level split, not provider-level — see `LzDivergentSpokeTransceiver` for
///         the full reasoning (`addressesDiverge` and the prediction formula have to agree,
///         so the choice is made by picking a contract, not a flag).

/// @dev Overrides both seams: zkSync diverges in deployment mechanism as well as address.
contract CcipZkSyncSpokeTransceiver is ZkSyncSpokeTransceiver {
    /// @param accountBytecodeHash_ ZKSOLC artifact hash for `CrossProxy`, not
    ///        `CROSS_PROXY_INIT_CODE_HASH` (solc's, meaningless on Era).
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bytes32 accountBytecodeHash_
    ) external initializer {
        __SpokeTransceiverBase_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            true
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

    /// @notice No gateway granted yet.
}

/// @dev Overrides prediction only: Tron runs raw-initcode CREATE2 with a different address.
contract CcipTronSpokeTransceiver is TronSpokeTransceiver {
    /// @param accountBytecodeHash_ TRON-solc's `CrossProxy` initcode hash, not solc's.
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bytes32 accountBytecodeHash_
    ) external initializer {
        __SpokeTransceiverBase_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            true
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

    /// @notice No gateway granted yet.
}
