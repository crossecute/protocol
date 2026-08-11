// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @title Payload
/// @notice The wire encoding of a call array, in the one shape its destination speaks.
///
/// @dev THE FORM FOLLOWS THE DESTINATION, NOT THE MESSAGE. An EVM destination always
///      receives `Call[]`; every other VM always receives opaque `bytes[]`, whose elements
///      are that chain's own call encoding. The choice is a property of where the message
///      is going, which the sender knows before it builds anything and the receiver knows
///      at compile time.
///
/// @dev WHICH IS WHY THERE IS NO FORM TAG. The sender picks by destination and the
///      receiver decodes the single shape its own VM implies, so a tag would carry a value
///      both sides already hold. That is exactly the field `Envelope` refuses to declare,
///      for the same reason: every channel carries one shape, so nothing needs to say
///      which.
///
///      That is a STRUCTURAL guarantee rather than a decoder one, and the distinction
///      matters. `abi.decode` of the wrong shape happens to revert for these two layouts,
///      but that is a property of how they collide, not a promise the ABI decoder makes.
///      What actually prevents a misread is that no path exists which sends opaque
///      elements to an EVM receiver. If one is ever added (a transmitter running on a
///      spoke, a destination that accepts both), the tag has to come back, because at that
///      point the direction stops determining the shape. This comment is the tripwire.
///
/// @dev THE COMMITMENT IS UNAFFECTED EITHER WAY. `Commitment` folds `keccak256(element)`
///      one element at a time and never sees the array framing, and `Calls.encode` produces
///      exactly the element the opaque form carries. So the two encodings of one payload
///      commit to one hash, an approval computed over portable `bytes[]` is discharged by
///      the typed array, and the wire format can change without invalidating a commitment.
library Payload {
    /* ============================== EVM destinations ============================ */

    /// @notice Wire bytes for an EVM destination.
    function encodeCalls(Call[] memory calls) internal pure returns (bytes memory) {
        return abi.encode(calls);
    }

    /// @notice Decode a payload that arrived on an EVM chain.
    /// @dev Reverts on anything that is not `Call[]`, which is the correct outcome here:
    ///      an element this receiver cannot decode is one it cannot execute, and the
    ///      commitment approves the array as a unit.
    function decodeCalls(bytes calldata wire) internal pure returns (Call[] memory) {
        return abi.decode(wire, (Call[]));
    }

    /* ============================ non-EVM destinations ========================== */

    /// @notice Wire bytes for a destination whose calls this chain cannot express.
    /// @dev The elements are that VM's own call encoding: a Solana instruction with its
    ///      account list, a Starknet `(to, selector, calldata)`, an Aptos entry function.
    ///      Nothing here parses one, and nothing here needs to.
    function encodeElements(bytes[] memory elements) internal pure returns (bytes memory) {
        return abi.encode(elements);
    }

    function decodeElements(bytes calldata wire) internal pure returns (bytes[] memory) {
        return abi.decode(wire, (bytes[]));
    }

    /* ================================ selection ================================= */

    /// @notice Whether a destination takes the typed form.
    ///
    /// @dev IT TAKES THE IDENTIFIER, NOT THE CHAINKEY, because a chainKey is
    ///      `keccak256(identifier)` and a hash cannot be asked what chain type it came from.
    ///      Anywhere the form still has to be chosen, the envelope is in hand:
    ///      `TransmitterBase.bootstrap(uint256, ...)` is `eip155` by construction and
    ///      `bootstrapTo(bytes, ...)` has the envelope as its argument. `sendMessage` does
    ///      not choose, because its payload arrives already built.
    function isTypedDestination(bytes memory chainIdentifier)
        internal
        pure
        returns (bool)
    {
        return Erc7930.parseStrict(chainIdentifier).chainType == Erc7930.CT_EIP155;
    }
}
