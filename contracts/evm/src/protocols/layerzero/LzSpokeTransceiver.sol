// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/SpokeTransceiverBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {LzCodec} from "./LzCodec.sol";

/// @notice The LayerZero transceiver on every chain that is not Ethereum.
///
/// @dev THE ENTIRE ROUTING LAYER IS TWO CONSTANTS. `HOME_CHAIN_KEY` names Ethereum and
///      `_homeRoute` is eid 30101; there is no registry to read, no eid table to
///      maintain, and no destination to choose. Compare `LzHubTransceiver`, which needs
///      all three because it faces N chains.
///
/// @dev The literal lives here rather than in a deploy script deliberately. An eid is
///      exactly the kind of value that is wrong once and wrong forever, and it belongs in
///      the source of the contract that uses it, where a reviewer reading the send path
///      will see it.
contract LzSpokeTransceiver is SpokeTransceiverBase, OwnableUpgradeable {
    /// @param homeTransceiver_ The Ethereum hub, in this chain's address format. Fixed
    ///        for the life of the contract — there is no setter, by design.
    function initialize(
        address owner_,
        address receiverImplementation_,
        bytes calldata homeTransceiver_
    ) external initializer {
        __Ownable_init(owner_);
        __TransceiverBase_init();
        __SpokeTransceiverBase_init(receiverImplementation_, homeTransceiver_);
    }

    /// @notice Satisfies `TransceiverBase._checkAdmin`. The local msig owns the spoke.
    /// @dev The same seam as on the hub: swapping in `OAppUpgradeable` changes this body,
    ///      not the base.
    function _checkAdmin() internal view override {
        _checkOwner();
    }

    /// @inheritdoc SpokeTransceiverBase
    function _homeRoute() internal pure override returns (bytes memory) {
        return LzCodec.encodeEid(LzCodec.ETHEREUM_EID);
    }

    /// @notice LayerZero's endpoint id for the hub. Exposed for off-chain checks.
    function homeEid() external pure returns (uint32) {
        return LzCodec.ETHEREUM_EID;
    }
}
