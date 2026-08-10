// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/SpokeTransceiverBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice The transceiver on every chain that is not the home chain.
///
/// @dev THE ENTIRE ROUTING LAYER IS THREE WRITE-ONCE VALUES. `homeChainKey` names the home
///      chain, `homeRoute()` holds its ERC-7930 chain identifier, and `homeTransceiver()`
///      holds the hub's address. There is no registry to read, no table to maintain, and
///      no destination to choose.
///
/// @dev THE ROUTE IS THE CHAIN IDENTIFIER, NOT A PROVIDER'S ID FOR IT. That is what makes
///      `keccak256(homeRoute()) == homeChainKey` true by construction rather than by
///      configuration, and it is what an ERC-7786 recipient is built from. The `uint32`
///      endpoint id this used to take is gone with `LzCodec`.
contract LzSpokeTransceiver is SpokeTransceiverBase, OwnableUpgradeable {
    /// @param homeChainKey_ keccak256 of the home chain's ERC-7930 chain identifier.
    /// @param homeChainIdentifier_ That identifier itself. It is passed rather than derived
    ///        because a chainKey is a hash and cannot be reversed, and it is checked
    ///        against `homeChainKey_` so the pair cannot disagree.
    /// @param homeTransceiver_ The hub, in this chain's address format. Fixed for the life
    ///        of the contract: there is no setter, by design.
    /// @param addressesDiverge_ True on zkSync and Tron, false on every EVM chain that
    ///        shares Ethereum's CREATE2 formula. See `SpokeTransceiverBase`.
    function initialize(
        address owner_,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bool addressesDiverge_
    ) external initializer {
        __Ownable_init(owner_);
        __TransceiverBase_init();
        __SpokeTransceiverBase_init(
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            addressesDiverge_
        );
    }

    /// @notice Satisfies `TransceiverBase._checkAdmin`. The local msig owns the spoke.
    function _checkAdmin() internal view override {
        _checkOwner();
    }
}
