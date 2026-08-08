// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Provenance} from "src/registry/ForeignRef.sol";

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
///      own name for a chain lives on the transceiver — the contract that sends and
///      receives — so what remains here is references: counterparts, account slots, and
///      the callback that records one.
interface IChainRegistryRefs {
    function transceiverFor(
        bytes32 chainKey,
        bytes32 messageProvider,
        Provenance minProvenance
    ) external view returns (bytes32 transceiverId, bytes memory location);

    function receiverSlot(bytes32 chainKey, address owner, bytes32 salt)
        external
        pure
        returns (bytes32);

    function onForeignRefResolved(
        bytes32 slot,
        bytes calldata interop,
        bytes calldata qualifierData
    ) external;

    function destinationReceiverOf(
        bytes32 chainKey,
        address owner,
        bytes32 salt,
        Provenance minProvenance
    ) external view returns (bytes memory);
}
