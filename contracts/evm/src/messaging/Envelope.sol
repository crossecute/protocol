// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";

/// @title Envelope
/// @notice The message bodies that cross between transceivers, each led by its kind.
///
/// @dev Tagged: once every transceiver both sends and receives bootstraps and reports, the
///      direction no longer decides the shape, and decoding the wrong shape can misread
///      silently. A decoder checks the tag before it reads anything else.
///
/// @dev Kinds start at 1, so a zero word, or the leading owner word of an untagged v1 body,
///      is refused rather than read as a kind.
///
/// @dev `abi.encode`, not `encodePacked`, so no two messages share a byte string.
library Envelope {
    uint8 internal constant BOOTSTRAP = 1;
    uint8 internal constant BOOTSTRAP_ELEMENTS = 2;
    uint8 internal constant RECEIVER_REPORT = 3;

    /// @dev Shorter than the one word that holds the kind.
    error EnvelopeTooShort();
    /// @dev The leading word is not a kind this protocol defines.
    error UnknownEnvelopeKind(uint256 kind);
    /// @dev A known kind, but not the one this decoder reads.
    error UnexpectedEnvelopeKind(uint8 expected, uint8 got);

    /// @notice The kind of `message`, reverting unless it is one this protocol defines.
    function kindOf(bytes calldata message) internal pure returns (uint8) {
        if (message.length < 32) revert EnvelopeTooShort();
        uint256 kind = abi.decode(message[:32], (uint256));
        if (kind == 0 || kind > RECEIVER_REPORT) revert UnknownEnvelopeKind(kind);
        // forge-lint: disable-next-line(unsafe-typecast) bounded by the check above
        return uint8(kind);
    }

    function _expect(bytes calldata message, uint8 kind) private pure {
        uint8 got = kindOf(message);
        if (got != kind) revert UnexpectedEnvelopeKind(kind, got);
    }

    /* ================================= bootstrap =============================== */

    /// @notice The payload that stands a receiver up, credited to the transmitter it
    ///         will answer to.
    ///
    /// @dev Calls, not a commitment: the transceiver creates and initializes the receiver and
    ///      is never in the path again. A payload that should wait carries a self-call to
    ///      `commit`.
    ///
    /// @dev Names the owner and salt, from which the destination derives the account address.
    ///      A transceiver is shared, so nothing the bridge reports says who authorized the
    ///      message.
    ///
    /// @dev Carries the transmitter the receiver will answer to, in the origin chain's own
    ///      address format. The origin transceiver sends only for the account `(owner, salt)`
    ///      resolves to there, so the value is vouched for by the same authenticated message,
    ///      and no destination needs another chain's address formula to derive it.
    function encodeBootstrap(address owner, bytes32 salt, bytes memory transmitter, Call[] memory calls)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(BOOTSTRAP, owner, salt, transmitter, calls);
    }

    function decodeBootstrap(bytes calldata message)
        internal
        pure
        returns (address owner, bytes32 salt, bytes memory transmitter, Call[] memory calls)
    {
        _expect(message, BOOTSTRAP);
        (, owner, salt, transmitter, calls) = abi.decode(message, (uint8, address, bytes32, bytes, Call[]));
    }

    /// @notice The same message, for a destination whose calls this chain cannot express.
    /// @dev No Solidity decoder: `SpokeTransceiverBase` is EVM-only, and a non-EVM transceiver
    ///      decodes this in its own language.
    function encodeBootstrapElements(address owner, bytes32 salt, bytes memory transmitter, bytes[] memory elements)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(BOOTSTRAP_ELEMENTS, owner, salt, transmitter, elements);
    }

    /* ============================== receiver report ============================= */

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
        return abi.encode(RECEIVER_REPORT, owner, salt, interop);
    }

    function decodeReceiverReport(bytes calldata message)
        internal
        pure
        returns (address owner, bytes32 salt, bytes memory interop)
    {
        _expect(message, RECEIVER_REPORT);
        (, owner, salt, interop) = abi.decode(message, (uint8, address, bytes32, bytes));
    }
}
