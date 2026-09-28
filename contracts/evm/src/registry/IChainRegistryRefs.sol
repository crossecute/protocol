// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Provenance} from "src/registry/Provenance.sol";

/// @notice The slice of `ChainRegistry` a hub transceiver needs: where remote things
///         live, and how much each claim about them is worth.
///
/// @dev The registry exists only on the home chain, so this stays out of the shared
///      transceiver base: a spoke has one counterpart, given at deployment, and no registry.
///
/// @dev Routes live on the transceiver. What the hub reads here is provenance, derived
///      counterpart addresses, location validation, and which chains must report their
///      receivers.
interface IChainRegistryRefs {
    /// @notice What an address claim about `chainKey` is worth. Chain-scoped, so every
    ///         provider's hub reads the same answer.
    function provenanceFor(bytes32 chainKey) external view returns (Provenance);

    /// @notice The transceiver address this registry recomputes for `chainKey`, from the
    ///         deriver and inputs recorded for that chain. A hub stores the result.
    function expectedTransceiver(bytes32 chainKey) external view returns (bytes memory);

    /// @notice The canonical ERC-7930 chain identifier `chainKey` hashes from.
    function chainIdentifier(bytes32 chainKey) external view returns (bytes memory);

    /// @notice Reverts unless `interop` is a well-formed address on `chainKey`.
    function validateLocation(bytes32 chainKey, bytes calldata interop) external view;

    /// @notice The derivation inputs recorded for `chainKey`. Hash this to build the
    ///         `paramsCommitment` a `resolveCounterpart` transaction must carry.
    function deriveParams(bytes32 chainKey) external view returns (bytes memory);

    /// @notice Whether accounts on `chainKey` must report their own address home, which is
    ///         the only thing this directory says about receivers. Where one actually landed
    ///         is held by the transmitter that sends to it.
    function requiresReceiverCallback(bytes32 chainKey) external view returns (bool);
}
