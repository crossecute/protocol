// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ZkSyncSpokeTransceiver, TronSpokeTransceiver} from
    "src/messaging/transceiver/spoke/DivergentSpokeTransceiver.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

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
contract LzZkSyncSpokeTransceiver is ZkSyncSpokeTransceiver, OwnableUpgradeable {
    /// @param accountBytecodeHash_ `AddressDerive.hashL2Bytecode` over the ZKSOLC artifact
    ///        for `CrossProxy`. Not `CROSS_PROXY_INIT_CODE_HASH`, which is keccak of solc's
    ///        initcode and means nothing on Era. Getting it wrong does not misdeliver:
    ///        every account creation reverts `AccountAddressMismatch` until it is right.
    function initialize(
        address owner_,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bytes32 accountBytecodeHash_
    ) external initializer {
        __Ownable_init(owner_);
        __SpokeTransceiverBase_init(
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            true
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

    /// @notice Satisfies `TransceiverBase.isAdmin`. The local msig owns the spoke.
    function isAdmin(address who) public view override returns (bool) {
        return who == owner();
    }

    /// @notice Which gateway may carry this contract's messages. Satisfies `GatewayBound`.
    /// @dev UNANSWERED UNTIL A BINDING EXISTS, so it accepts nothing. There is no LayerZero
    ///      gateway behind this yet, and a base that guessed an address would be worse than
    ///      one that refuses. A real binding returns `instance == address(endpoint)`.
    function _isAuthorizedGateway(address) internal pure override returns (bool) {
        return false;
    }

}

/// @notice Tron.
/// @dev It overrides the prediction only, because Tron runs raw-initcode CREATE2 and simply
///      derives a different address from it: see `TronSpokeTransceiver`.
contract LzTronSpokeTransceiver is TronSpokeTransceiver, OwnableUpgradeable {
    /// @param accountBytecodeHash_ `keccak256` of TRON-solc's `CrossProxy` initcode, which
    ///        is not solc's. See `LzZkSyncSpokeTransceiver` for why it is an argument.
    function initialize(
        address owner_,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bytes32 accountBytecodeHash_
    ) external initializer {
        __Ownable_init(owner_);
        __SpokeTransceiverBase_init(
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            true
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

    /// @notice Satisfies `TransceiverBase.isAdmin`. The local msig owns the spoke.
    function isAdmin(address who) public view override returns (bool) {
        return who == owner();
    }

    /// @notice Which gateway may carry this contract's messages. Satisfies `GatewayBound`.
    /// @dev UNANSWERED UNTIL A BINDING EXISTS, so it accepts nothing. There is no LayerZero
    ///      gateway behind this yet, and a base that guessed an address would be worse than
    ///      one that refuses. A real binding returns `instance == address(endpoint)`.
    function _isAuthorizedGateway(address) internal pure override returns (bool) {
        return false;
    }

}
