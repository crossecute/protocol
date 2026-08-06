// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Provenance} from "src/registry/ForeignRef.sol";

/// @notice The slice of `ChainRegistry` a hub transceiver needs.
///
/// @dev DECLARED SEPARATELY BECAUSE ONLY ONE SIDE HAS IT. The registry exists on
///      Ethereum and nowhere else: the hub has N counterparts and needs a directory to
///      tell them apart, while a spoke has exactly one and knows it at compile time.
///      Keeping this interface out of the shared transceiver base is what stops a spoke
///      from carrying a dependency it can never satisfy.
interface IChainRegistryRoutes {
    function transceiverFor(
        bytes32 chainKey,
        bytes32 messageProvider,
        Provenance minProvenance
    ) external view returns (bytes32 transceiverId, bytes memory location);

    function providerRoute(bytes32 chainKey, bytes32 messageProvider)
        external
        view
        returns (bytes memory route);

    function chainKeyOfRoute(bytes32 messageProvider, bytes calldata route)
        external
        view
        returns (bytes32 chainKey);

    function receiverSlot(bytes32 chainKey, address transmitter)
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
        address transmitter,
        Provenance minProvenance
    ) external view returns (bytes memory);
}
