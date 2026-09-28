// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @title Payload
/// @notice The wire encoding of a call array, in the one shape its destination speaks.
///
/// @dev An EVM destination receives `Call[]`; every other VM receives opaque `bytes[]` in its
///      own call encoding. The sender picks by destination and the receiver decodes the one
///      shape its VM implies, so there is no form tag.
///
/// @dev That relies on no path sending opaque elements to an EVM receiver, not on
///      `abi.decode` rejecting the wrong shape. A path that could (a transmitter on a spoke, a
///      destination accepting both) needs the tag back.
///
/// @dev Both forms of one payload commit to one hash: `Commitment` folds per-element hashes
///      and `Calls.encode` produces exactly the opaque element.
library Payload {
    /* ============================== EVM destinations ============================ */

    /// @notice Wire bytes for an EVM destination.
    function encodeCalls(Call[] memory calls) internal pure returns (bytes memory) {
        return abi.encode(calls);
    }

    /// @notice Decode a payload that arrived on an EVM chain. Reverts on anything that is not
    ///         `Call[]`.
    function decodeCalls(bytes calldata wire) internal pure returns (Call[] memory) {
        return abi.decode(wire, (Call[]));
    }

    /* ============================ non-EVM destinations ========================== */

    /// @notice Wire bytes for a destination whose calls this chain cannot express.
    /// @dev Each element is that VM's own call encoding (a Solana instruction with its
    ///      accounts, a Starknet `(to, selector, calldata)`, an Aptos entry function), unparsed
    ///      here.
    function encodeElements(bytes[] memory elements) internal pure returns (bytes memory) {
        return abi.encode(elements);
    }

    function decodeElements(bytes calldata wire) internal pure returns (bytes[] memory) {
        return abi.decode(wire, (bytes[]));
    }

    /* ================================ selection ================================= */

    /// @notice Whether a destination takes the typed form.
    /// @dev Takes the identifier, not the chainKey, which is a hash and cannot be asked its
    ///      chain type.
    function isTypedDestination(bytes memory chainIdentifier) internal pure returns (bool) {
        return Erc7930.parseStrict(chainIdentifier).chainType == Erc7930.CT_EIP155;
    }
}
