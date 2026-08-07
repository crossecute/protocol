// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";

/// @title Envelope
/// @notice The two message bodies that cross between transceivers.
///
/// @dev THERE IS NO MESSAGE-TYPE TAG, AND THAT IS A PROPERTY OF THE TOPOLOGY. Bootstrap
///      messages travel hub -> spoke and receiver reports travel spoke -> hub, so each
///      side decodes exactly one shape and the direction is the discriminant. A tag would
///      be a field whose only correct value each contract already knows.
///
///      That holds because transmitters live on Ethereum only. If one ever runs on a
///      spoke, the hub starts receiving commitments as well as reports, the direction
///      stops determining the shape, and a tag becomes mandatory — decoding the wrong
///      shape off a `bytes` blob is not a revert, it is a silent misread. This comment is
///      the tripwire for that change.
///
/// @dev The bodies are `abi.encode`, not `encodePacked`. Both carry a variable-length or
///      address-typed field, and packed encoding is how two different messages come to
///      share a byte string.
library Envelope {
    /* ============================== hub -> spoke =============================== */

    /// @notice The payload that stands a receiver up, credited to the transmitter it
    ///         will answer to.
    ///
    /// @dev IT CARRIES CALLS, NOT A COMMITMENT. A transceiver does not relay approvals; it
    ///      creates a receiver and initializes it with the payload that justified doing so,
    ///      in one transaction, and is never in the path again. A payload that should wait
    ///      rather than run carries a self-call to the receiver's own `commit`, so this
    ///      envelope needs no second shape for the deferred case.
    ///
    /// @dev THE OWNER AND THE SALT ARE IN THE MESSAGE, AND IT IS THE OWNER RATHER THAN THE
    ///      TRANSMITTER. The destination derives the account address from the pair —
    ///      `accountSalt(owner, salt)` —
    ///      which is what puts an owner's transmitter and their receivers on one address.
    ///      The transmitter's own address could not serve: a CREATE2 address cannot be
    ///      derived from itself. Nothing the bridge reports says who on Ethereum authorized
    ///      the message, since the hub is shared by every owner, so it is stated.
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
    ///      would carry a value both already hold — the same reason nothing else here has
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
    ///      whose address Ethereum computes before the first message; Starknet's is a
    ///      Pedersen hash chain that the EVM cannot run at any price, so the destination
    ///      creates it, learns the address, and says so.
    ///
    /// @dev IT CARRIES NO REQUEST ID, because the fields it does carry already imply the
    ///      correlation one would provide: the destination is established by the
    ///      authenticated origin, and `(owner, salt)` is stated here — exactly the triple
    ///      the receiver slot is derived from. The registry refuses a second write to that
    ///      slot outright, which is a stronger guarantee than matching an id.
    ///
    ///      It states the OWNER AND SALT rather than the account's address, matching the
    ///      bootstrap message it answers. The address is a derivation of that pair, so the
    ///      pair is what identifies the account.
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
