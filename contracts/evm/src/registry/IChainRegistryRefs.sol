// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Provenance} from "src/registry/Provenance.sol";

/// @notice The slice of `ChainRegistry` a hub transceiver needs: where remote things
///         live, and how much each claim about them is worth.
///
/// @dev DECLARED SEPARATELY BECAUSE ONLY ONE SIDE HAS IT. The registry exists on the
///      home chain and nowhere else: the hub has N counterparts and needs a directory to
///      tell them apart, while a spoke has exactly one and is told which at deployment.
///      Keeping this interface out of the shared transceiver base is what stops a spoke
///      from carrying a dependency it can never satisfy.
///
/// @dev IT HOLDS NO ROUTES, WHICH IS WHY IT IS NOT NAMED FOR THEM. A message provider's
///      own name for a chain lives on the transceiver (the contract that sends and
///      receives), so what remains here is references: counterparts, account slots, and
///      the callback that records one.
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
