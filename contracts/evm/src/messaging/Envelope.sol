// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";

/// @title Envelope
/// @notice The two message bodies that cross between transceivers.
///
/// @dev THERE IS NO MESSAGE-TYPE TAG, AND THAT IS A PROPERTY OF THE TOPOLOGY. Bootstraps
///      travel hub -> spoke and reports travel spoke -> hub, so each side decodes exactly one
///      shape and the direction is the discriminant.
///
///      TRIPWIRE: that holds only because transmitters live on the home chain. If one ever
///      runs on a spoke, the hub starts receiving commitments as well as reports, direction
///      stops determining shape, and a tag becomes mandatory, because decoding the wrong
///      shape off a `bytes` blob is a silent misread rather than a revert.
///
/// @dev The bodies are `abi.encode`, not `encodePacked`. Both carry a variable-length or
///      address-typed field, and packed encoding is how two different messages come to
///      share a byte string.
library Envelope {
    /* ============================== hub -> spoke =============================== */

    /// @notice The payload that stands a receiver up, credited to the transmitter it
    ///         will answer to.
    ///
    /// @dev IT CARRIES CALLS, NOT A COMMITMENT. A transceiver does not relay approvals: it
    ///      creates a receiver, initializes it with the payload that justified doing so, and
    ///      is never in the path again. A payload that should wait carries a self-call to the
    ///      receiver's own `commit`, so this needs no second shape for the deferred case.
    ///
    /// @dev IT NAMES THE OWNER AND SALT RATHER THAN THE TRANSMITTER, because the destination
    ///      derives the account address from that pair and a CREATE2 address cannot be
    ///      derived from itself. It has to be stated because the hub is shared by every
    ///      owner, so nothing the bridge reports says who authorized the message.
    function encodeBootstrap(address owner, bytes32 salt, Call[] memory calls)
        internal
        pure
        returns (bytes memory)
    {
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
    ///
    /// @dev A SECOND SHAPE, NOT A TAGGED ONE. Which form a spoke receives follows from its
    ///      VM: an EVM spoke decodes `Call[]`, a Solana or Move one decodes its own
    ///      elements. Each side knows which before a byte is written, so a discriminant
    ///      would carry a value both already hold: the same reason nothing else here has
    ///      a type tag.
    ///
    ///      There is no `decodeBootstrapElements` because nothing written in Solidity ever
    ///      receives one. `SpokeTransceiverBase` runs on an EVM chain by construction; the
    ///      decoder for this lives in whatever language that destination speaks.
    function encodeBootstrapElements(
        address owner,
        bytes32 salt,
        bytes[] memory elements
    ) internal pure returns (bytes memory) {
        return abi.encode(owner, salt, elements);
    }

    /* ============================== spoke -> hub =============================== */

    /// @notice Where the destination created a transmitter's receiver.
    ///
    /// @dev Only underivable chains need this. An EVM spoke's receiver is a CREATE2 clone
    ///      whose address the hub computes before the first message; Starknet's is a
    ///      Pedersen hash chain that the EVM cannot run at any price, so the destination
    ///      creates it, learns the address, and says so.
    ///
    /// @dev IT CARRIES NO REQUEST ID, because the fields it does carry already imply the
    ///      correlation one would provide: the chain comes from the authenticated origin and
    ///      `(owner, salt)` is stated here, which is exactly the triple the receiver slot is
    ///      derived from. The registry refuses a second write to that slot outright, which is
    ///      stronger than matching an id.
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
