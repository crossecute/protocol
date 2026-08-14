// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ZkSyncSpokeTransceiver, TronSpokeTransceiver} from
    "src/messaging/transceiver/spoke/DivergentSpokeTransceiver.sol";

/// @notice The spoke on a chain whose CREATE2 formula is not Ethereum's: zkSync Era and
///         Tron. One concrete contract each, because the two diverge differently.
///
/// @dev THEY EXIST SO THE CHOICE IS MADE AT DEPLOY TIME, BY PICKING A CONTRACT. Divergence
///      is two facts that have to agree: `addressesDiverge`, which tells the hub it cannot
///      derive an account's address here, and `predictCrossAccount`, which is the
///      arithmetic that makes that true. Setting them independently is a way to get a spoke
///      whose flag and formula disagree, and `LzSpokeTransceiver` taking the flag as an
///      argument was exactly that.
///
///      Here neither is an argument. A parity chain gets `LzSpokeTransceiver`, which is
///      Ethereum's formula and `addressesDiverge = false`; a diverging chain gets one of
///      these, which is that chain's formula and `true`. The pair is exhaustive and
///      mutually exclusive, so the flag stops being a thing anyone can set wrongly.

/// @notice zkSync Era.
/// @dev It overrides both seams, because zkSync diverges in the deployment mechanism as
///      well as the address: see `ZkSyncSpokeTransceiver`.
contract LzZkSyncSpokeTransceiver is ZkSyncSpokeTransceiver {
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
    /// @dev That is the honest state of a binding with no LayerZero behind it. A real binding
    ///      grants `GATEWAY_ROLE` to its endpoint in the initializer, which is where the
    ///      address is known; the absence fails loudly on the first message rather than
    ///      quietly on a forged one.

}

/// @notice Tron.
/// @dev It overrides the prediction only, because Tron runs raw-initcode CREATE2 and simply
///      derives a different address from it: see `TronSpokeTransceiver`.
contract LzTronSpokeTransceiver is TronSpokeTransceiver {
    /// @param accountBytecodeHash_ `keccak256` of TRON-solc's `CrossProxy` initcode, which
    ///        is not solc's. See `LzZkSyncSpokeTransceiver` for why it is an argument.
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
    /// @dev That is the honest state of a binding with no LayerZero behind it. A real binding
    ///      grants `GATEWAY_ROLE` to its endpoint in the initializer, which is where the
    ///      address is known; the absence fails loudly on the first message rather than
    ///      quietly on a forged one.

}
