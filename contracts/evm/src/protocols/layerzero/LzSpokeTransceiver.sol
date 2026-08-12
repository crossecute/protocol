// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice The transceiver on every chain that is not the home chain.
///
/// @dev THE ENTIRE ROUTING LAYER IS THREE WRITE-ONCE VALUES: `homeChainKey`, `homeRoute()`
///      holding that chain's ERC-7930 identifier, and `homeTransceiver()` holding the hub's
///      address. No registry to read, no table to maintain, no destination to choose.
///
/// @dev THE ROUTE IS THE CHAIN IDENTIFIER, NOT A PROVIDER'S ID FOR IT, which makes
///      `keccak256(homeRoute()) == homeChainKey` true by construction rather than by
///      configuration, and is what an ERC-7786 recipient is built from.
contract LzSpokeTransceiver is SpokeTransceiverBase, OwnableUpgradeable {
    /// @param homeChainKey_ keccak256 of the home chain's ERC-7930 chain identifier.
    /// @param homeChainIdentifier_ That identifier itself. It is passed rather than derived
    ///        because a chainKey is a hash and cannot be reversed, and it is checked
    ///        against `homeChainKey_` so the pair cannot disagree.
    /// @param homeTransceiver_ The hub, in this chain's address format. Fixed for the life
    ///        of the contract: there is no setter, by design.
    /// @dev THIS IS THE PARITY SPOKE, AND IT DOES NOT TAKE THE DIVERGENCE FLAG. It inherits
    ///      `TransceiverBase.predictCrossAccount`, which is Ethereum's CREATE2 formula and
    ///      exactly what the hub recomputes, so accounts here do NOT diverge and the flag is
    ///      `false` by construction rather than by configuration.
    ///
    ///      Taking it as an argument allowed the one state that cannot be right: `true` with
    ///      Ethereum's arithmetic, which reports addresses home that the hub could already
    ///      derive, and downgrades a `Derived` fact to an `Attested` one for nothing. A
    ///      chain that really diverges needs different arithmetic as well as the flag, so it
    ///      gets `LzZkSyncSpokeTransceiver` or `LzTronSpokeTransceiver` instead.
    function initialize(
        address owner_,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_
    ) external initializer {
        __Ownable_init(owner_);
        __SpokeTransceiverBase_init(
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            false
        );
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
