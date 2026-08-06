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
    /// @dev THE OWNER IS IN THE MESSAGE, AND IT IS THE OWNER RATHER THAN THE TRANSMITTER.
    ///      The destination derives the account address from it — `accountSalt(owner)` —
    ///      which is what puts an owner's transmitter and their receivers on one address.
    ///      The transmitter's own address could not serve: a CREATE2 address cannot be
    ///      derived from itself. Nothing the bridge reports says who on Ethereum authorized
    ///      the message, since the hub is shared by every owner, so it is stated.
    function encodeBootstrap(address owner, Call[] memory calls)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(owner, calls);
    }

    function decodeBootstrap(bytes calldata message)
        internal
        pure
        returns (address owner, Call[] memory calls)
    {
        (owner, calls) = abi.decode(message, (address, Call[]));
    }

    /* ============================== spoke -> hub =============================== */

    /// @notice Where the destination created a transmitter's receiver.
    ///
    /// @dev Only underivable chains need this. An EVM spoke's receiver is a CREATE2 clone
    ///      whose address Ethereum computes before the first message; Starknet's is a
    ///      Pedersen hash chain that the EVM cannot run at any price, so the destination
    ///      creates it, learns the address, and says so.
    ///
    /// @dev IT CARRIES NO REQUEST ID, because the two fields it does carry already imply
    ///      the correlation one would provide: the destination is established by the
    ///      authenticated origin and the transmitter is stated here, which is exactly the
    ///      pair the receiver slot is derived from. The registry refuses a second write to
    ///      that slot outright, which is a stronger guarantee than matching an id.
    /// @param interop Canonical ERC-7930 bytes for the receiver on the reporting chain.
    function encodeReceiverReport(address transmitter, bytes memory interop)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(transmitter, interop);
    }

    function decodeReceiverReport(bytes calldata message)
        internal
        pure
        returns (address transmitter, bytes memory interop)
    {
        (transmitter, interop) = abi.decode(message, (address, bytes));
    }
}
