// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {Bytes} from "src/messaging/signed/Bytes.sol";

/// @notice Safe 1.5.0 signature blob parsing shared by the receiver's verifier and the source's
///         evidence collection.
/// @dev Only the first threshold-many 65-byte entries are read, as in `Safe.checkNSignatures`, so
///      bytes after them that no read entry points into are unauthenticated and ignored.
library SafeSignaturesUtils {
    // SignMessageLib.signMessage(bytes)
    bytes4 internal constant SIGN_MESSAGE = 0x85a5affe;
    uint8 internal constant DELEGATECALL = 1;

    error SignaturesTooShort(address safe);
    /// @dev `v = 1`: a pre-approved hash or the executor's own entry, neither checkable here.
    error ApprovedHashUnsupported(address safe);
    error InvalidSignatureType(uint8 v);
    /// @dev A contract signature's offset or length leaves the blob or enters its static part.
    error MalformedContractSignature(address safe);
    /// @dev The evidence is not a DELEGATECALL of `signMessage(abi.encode(parentHash))`.
    error NotANestedSafeApprovalOf(address childSafe, bytes32 parentHash);

    /// @notice Check that the blob contains enough 65-byte entries for the required signatures.
    /// @dev Call this before reading entries so truncated input cannot be mistaken for a
    ///      complete quorum.
    function requireLength(address safe, bytes memory signatures, uint256 threshold) internal pure {
        if (signatures.length < threshold * 65) revert SignaturesTooShort(safe);
    }

    /// @notice Read the `r`, `s` and `v` fields of one 65-byte Safe signature entry.
    /// @dev `v` tells the caller how to interpret the entry. Reject `v = 1` because source-side
    ///      hash approvals and executor identity cannot be reproduced on the receiver. The
    ///      caller must check the blob length first.
    function entry(address safe, bytes memory signatures, uint256 index)
        internal
        pure
        returns (bytes32 r, bytes32 s, uint8 v)
    {
        assembly ("memory-safe") {
            let at := add(add(signatures, 0x20), mul(index, 65))
            r := mload(at)
            s := mload(add(at, 0x20))
            v := byte(0, mload(add(at, 0x40)))
        }
        if (v == 1) revert ApprovedHashUnsupported(safe);
    }

    /// @notice Recover the EOA address for a direct or Ethereum-prefixed ECDSA signature.
    /// @dev Safe uses `v = 27/28` for the supplied hash and `31/32` for its `eth_sign` digest.
    ///      Other values revert. The caller must still check owner membership; an invalid
    ///      recovery can return zero.
    function recover(bytes32 dataHash, bytes32 r, bytes32 s, uint8 v) internal pure returns (address) {
        // forge-lint: disable-next-line(ecrecover) as Safe: a malleable twin recovers the same owner, which the ascending check refuses twice
        if (v == 27 || v == 28) return ecrecover(dataHash, v, r, s);
        if (v == 31 || v == 32) {
            // forge-lint: disable-next-line(ecrecover) as above
            return ecrecover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash)), v - 4, r, s);
        }
        revert InvalidSignatureType(v);
    }

    /// @notice Extract the child contract's signature bytes from a Safe signature blob.
    /// @dev A contract-owner entry (`v = 0`) puts its address in `r` and a payload offset in
    ///      `s`, rather than containing an EOA signature. Read the length-prefixed bytes at
    ///      that offset so the caller can verify the child's own signatures. Check the offset
    ///      and length against the blob and required static entries; extraction alone does not
    ///      authenticate the child. Empty payloads are returned for the separate
    ///      approval-evidence path. As in Safe, payloads may overlap or occupy bytes after the
    ///      required static entries.
    function extractContractSignature(address safe, bytes memory signatures, uint256 offset, uint256 threshold)
        internal
        pure
        returns (bytes memory)
    {
        uint256 total = signatures.length;
        if (offset < threshold * 65 || offset > total || total - offset < 32) revert MalformedContractSignature(safe);
        uint256 length;
        assembly ("memory-safe") {
            length := mload(add(add(signatures, 0x20), offset))
        }
        if (length > total - offset - 32) revert MalformedContractSignature(safe);
        return Bytes.slice(signatures, offset + 32, length);
    }

    /// @notice Compute the child Safe's message hash for the parent's signed hash.
    /// @dev Binding the parent's hash to the child Safe and source chain matches Safe's
    ///      fallback handler and prevents reusing a child's signatures for a different Safe
    ///      domain.
    function nestedHash(bytes32 parentHash, address child, uint256 chainId) internal pure returns (bytes32) {
        return SafeHashes.messageHash(abi.encode(parentHash), child, chainId);
    }

    /// @notice Check that a transaction approves this parent hash, then compute its child Safe
    ///         transaction hash.
    /// @dev An empty nested signature needs separate evidence: a signed DELEGATECALL of
    ///      `signMessage(abi.encode(parentHash))`. The caller verifies the child's quorum over
    ///      the returned hash. The target is bound into that hash but is not independently
    ///      checked here; calldata is decoded as Safe's SignMessageLib decodes it, without
    ///      requiring canonical encoding.
    function approvalHash(address child, bytes32 parentHash, SafeTx memory approval, uint256 chainId)
        internal
        pure
        returns (bytes32)
    {
        bytes memory data = approval.data;
        // forge-lint: disable-next-line(unsafe-typecast) the first four bytes, after the length check
        if (approval.operation != DELEGATECALL || data.length < 4 || bytes4(data) != SIGN_MESSAGE) {
            revert NotANestedSafeApprovalOf(child, parentHash);
        }
        bytes memory message = abi.decode(Bytes.slice(data, 4, data.length - 4), (bytes));
        if (keccak256(message) != keccak256(abi.encode(parentHash))) {
            revert NotANestedSafeApprovalOf(child, parentHash);
        }
        return SafeHashes.transactionHash(approval, child, chainId);
    }
}
