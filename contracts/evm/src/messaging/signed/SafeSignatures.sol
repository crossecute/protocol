// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {Slices} from "src/messaging/signed/Slices.sol";

/// @notice Safe 1.5.0 signature blob parsing shared by the receiver's verifier and the source's
///         evidence collection.
/// @dev Only the first threshold-many 65-byte entries are read, as in `Safe.checkNSignatures`, so
///      bytes after them that no read entry points into are unauthenticated and ignored.
library SafeSignatures {
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
    error NotAnApprovalOf(address childSafe, bytes32 parentHash);

    function requireLength(address safe, bytes memory signatures, uint256 threshold) internal pure {
        if (signatures.length < threshold * 65) revert SignaturesTooShort(safe);
    }

    /// @notice Entry `index` of `signatures`, with `v = 1` refused.
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

    /// @notice The EOA behind an ECDSA entry: `v` of 27 or 28 over `dataHash`, 31 or 32 over its
    ///         eth_sign digest. Any other `v` reverts.
    function recover(bytes32 dataHash, bytes32 r, bytes32 s, uint8 v) internal pure returns (address) {
        // forge-lint: disable-next-line(ecrecover) as Safe: a malleable twin recovers the same owner, which the ascending check refuses twice
        if (v == 27 || v == 28) return ecrecover(dataHash, v, r, s);
        if (v == 31 || v == 32) {
            // forge-lint: disable-next-line(ecrecover) as above
            return ecrecover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash)), v - 4, r, s);
        }
        revert InvalidSignatureType(v);
    }

    /// @notice The length-prefixed payload a `v = 0` entry points to, under Safe's bounds (GS021
    ///         to GS023). Payloads may overlap and may sit among entries past the threshold.
    function contractSignature(address safe, bytes memory signatures, uint256 offset, uint256 threshold)
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
        return Slices.slice(signatures, offset + 32, length);
    }

    /// @notice What a nested Safe signs for its parent: the child-domain `SafeMessage` hash of
    ///         `abi.encode(parentHash)`, as `CompatibilityFallbackHandler` computes it.
    function nestedHash(bytes32 parentHash, address child, uint256 chainId) internal pure returns (bytes32) {
        return SafeHashes.messageHash(abi.encode(parentHash), child, chainId);
    }

    /// @notice The child Safe transaction hash `approval`'s signatures cover, once it is shown to
    ///         be the child's DELEGATECALL of `signMessage(abi.encode(parentHash))`.
    /// @dev The target is in the hash and not otherwise checked: the child's quorum over this
    ///      call authorizes the message in its calldata, whatever the library wrote. The calldata
    ///      is decoded as Safe's `SignMessageLib` decodes it, without requiring canonical bytes.
    function approvalHash(address child, bytes32 parentHash, SafeTx memory approval, uint256 chainId)
        internal
        pure
        returns (bytes32)
    {
        bytes memory data = approval.data;
        // forge-lint: disable-next-line(unsafe-typecast) the first four bytes, after the length check
        if (approval.operation != DELEGATECALL || data.length < 4 || bytes4(data) != SIGN_MESSAGE) {
            revert NotAnApprovalOf(child, parentHash);
        }
        bytes memory message = abi.decode(Slices.slice(data, 4, data.length - 4), (bytes));
        if (keccak256(message) != keccak256(abi.encode(parentHash))) revert NotAnApprovalOf(child, parentHash);
        return SafeHashes.transactionHash(approval, child, chainId);
    }
}
