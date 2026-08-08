// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/SpokeTransceiverBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {LzCodec} from "./LzCodec.sol";

/// @notice The LayerZero transceiver on every chain that is not the home chain.
///
/// @dev THE ENTIRE ROUTING LAYER IS THREE WRITE-ONCE VALUES. `homeChainKey` names the
///      home chain, `homeRoute()` holds its eid, and `homeTransceiver()` holds the hub's
///      address; there is no registry to read, no eid table to maintain, and no
///      destination to choose. Compare `LzHubTransceiver`, which needs all three because
///      it faces N chains.
///
/// @dev The eid is an initializer argument rather than a literal because the home chain
///      is a deployment choice: see `SpokeTransceiverBase`. It is still wrong once and
///      wrong forever, which is why there is no setter for it.
contract LzSpokeTransceiver is SpokeTransceiverBase, OwnableUpgradeable {
    /// @param homeChainKey_ keccak256 of the home chain's ERC-7930 chain identifier,
    ///        `ChainKey.forEvm(1)` if the deployment anchors on Ethereum.
    /// @param homeEid_ LayerZero's endpoint id for that chain. Typed here, opaque in the
    ///        base, which is the same split `setEid` uses on the hub.
    /// @param homeTransceiver_ The hub, in this chain's address format. Fixed for the life
    ///        of the contract: there is no setter, by design.
    function initialize(
        address owner_,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        uint32 homeEid_,
        bytes calldata homeTransceiver_
    ) external initializer {
        __Ownable_init(owner_);
        __TransceiverBase_init();
        __SpokeTransceiverBase_init(
            receiverImplementation_,
            homeChainKey_,
            LzCodec.encodeEid(homeEid_),
            homeTransceiver_
        );
    }

    /// @notice Satisfies `TransceiverBase._checkAdmin`. The local msig owns the spoke.
    /// @dev The same seam as on the hub: swapping in `OAppUpgradeable` changes this body,
    ///      not the base.
    function _checkAdmin() internal view override {
        _checkOwner();
    }

    /// @notice LayerZero's endpoint id for the hub. Exposed for off-chain checks.
    /// @dev A spoke needs no route TABLE: it has exactly one destination, written once.
    ///      `setEid` exists only on the hub, which faces N chains.
    function homeEid() external view returns (uint32) {
        return LzCodec.decodeEid(homeRoute());
    }
}
