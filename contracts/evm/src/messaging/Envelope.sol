// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";

/// @title Envelope
/// @notice The two message bodies that cross between transceivers.
///
/// @dev No type tag: bootstraps travel hub to spoke and reports spoke to hub, so direction
///      decides the shape. That holds only while transmitters live on the home chain and a
///      spoke refuses `bootstrap`; otherwise a tag is needed, since decoding the wrong shape
///      can misread silently.
///
/// @dev `abi.encode`, not `encodePacked`, so no two messages share a byte string.
library Envelope {
    /* ============================== hub -> spoke =============================== */

    /// @notice The payload that stands a receiver up, credited to the transmitter it
    ///         will answer to.
    ///
    /// @dev Calls, not a commitment: the transceiver creates and initializes the receiver and
    ///      is never in the path again. A payload that should wait carries a self-call to
    ///      `commit`.
    ///
    /// @dev Names the owner and salt, from which the destination derives the account address.
    ///      The hub is shared, so nothing the bridge reports says who authorized the message.
    function encodeBootstrap(address owner, bytes32 salt, Call[] memory calls) internal pure returns (bytes memory) {
        return abi.encode(owner, salt, calls);
    }

    function decodeBootstrap(bytes calldata message)
        internal
        pure
        returns (address owner, bytes32 salt, Call[] memory calls)
    {
        (owner, salt, calls) = abi.decode(message, (address, bytes32, Call[]));
    }

    /// @notice The same message, for a destination whose calls this chain cannot express.
    /// @dev A second shape, chosen by the spoke's VM. No Solidity decoder: `SpokeTransceiverBase`
    ///      is EVM-only, and a non-EVM spoke decodes this in its own language.
    function encodeBootstrapElements(address owner, bytes32 salt, bytes[] memory elements)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(owner, salt, elements);
    }

    /* ============================== spoke -> hub =============================== */

    /// @notice Where the destination created a transmitter's receiver.
    ///
    /// @dev Only chains whose addresses the hub cannot recompute send this: zkSync and Tron,
    ///      whose CREATE2 formulas differ, and non-EVM chains such as Starknet.
    ///
    /// @dev No request id: the chain comes from the authenticated origin and `(owner, salt)`
    ///      is stated here, which identifies the account the hub forwards the report to. The
    ///      account refuses a second report.
    /// @param interop Canonical ERC-7930 bytes for the receiver on the reporting chain.
    function encodeReceiverReport(address owner, bytes32 salt, bytes memory interop)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(owner, salt, interop);
    }

    function decodeReceiverReport(bytes calldata message)
        internal
        pure
        returns (address owner, bytes32 salt, bytes memory interop)
    {
        (owner, salt, interop) = abi.decode(message, (address, bytes32, bytes));
    }
}
