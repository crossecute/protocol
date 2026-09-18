// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ZkSyncSpokeTransceiver, TronSpokeTransceiver} from
    "src/messaging/transceiver/spoke/DivergentSpokeTransceiver.sol";

/// @notice The spoke on a chain whose CREATE2 formula is not Ethereum's: zkSync Era and
///         Tron. One concrete contract each, because the two diverge differently.
///
/// @dev THIS SPLIT IS PROTOCOL-LEVEL, NOT PROVIDER-LEVEL, AND NOTHING HERE CHANGES BY
///      PROVIDER. See `LzDivergentSpokeTransceiver` for the full reasoning: divergence is two
///      facts that have to agree (`addressesDiverge` and the prediction formula), and picking
///      one of these two contracts at deploy time is what keeps them from being set
///      independently and wrongly. Wormhole's own chain-id table is exactly as orthogonal to
///      this as LayerZero's eid table, CCIP's selector table, and Hyperlane's domain table
///      were: whichever provider carries the message, zkSync and Tron still need their own
///      address arithmetic.

/// @notice zkSync Era.
/// @dev It overrides both seams, because zkSync diverges in the deployment mechanism as
///      well as the address: see `ZkSyncSpokeTransceiver`.
contract WormholeZkSyncSpokeTransceiver is ZkSyncSpokeTransceiver {
    /// @param accountBytecodeHash_ `AddressDerive.hashL2Bytecode` over the ZKSOLC artifact
    ///        for `CrossProxy`. Not `CROSS_PROXY_INIT_CODE_HASH`, which is keccak of solc's
    ///        initcode and means nothing on Era. Getting it wrong does not misdeliver:
    ///        every account creation reverts `AccountAddressMismatch` until it is right.
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

    /// @notice NO GATEWAY IS GRANTED, so this contract accepts and sends through nothing.
    /// @dev That is the honest state of a binding with no Wormhole behind it. A real binding
    ///      grants `GATEWAY_ROLE` to the Wormhole Relayer in the initializer, which is where
    ///      the address is known; the absence fails loudly on the first message rather than
    ///      quietly on a forged one.

}

/// @notice Tron.
/// @dev It overrides the prediction only, because Tron runs raw-initcode CREATE2 and simply
///      derives a different address from it: see `TronSpokeTransceiver`.
contract WormholeTronSpokeTransceiver is TronSpokeTransceiver {
    /// @param accountBytecodeHash_ `keccak256` of TRON-solc's `CrossProxy` initcode, which
    ///        is not solc's. See `WormholeZkSyncSpokeTransceiver` for why it is an argument.
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

    /// @notice NO GATEWAY IS GRANTED, so this contract accepts and sends through nothing.
    /// @dev That is the honest state of a binding with no Wormhole behind it. A real binding
    ///      grants `GATEWAY_ROLE` to the Wormhole Relayer in the initializer, which is where
    ///      the address is known; the absence fails loudly on the first message rather than
    ///      quietly on a forged one.

}
