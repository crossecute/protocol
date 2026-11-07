// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Operation} from "policy-engine/interfaces/Operation.sol";

/// @notice What a transmitter consumes from the guard, and what a relayer reads from it.
interface ICrossecuteGuard {
    /// @notice A Safe's staged dispatch: the signed transaction and its complete signature blob.
    /// @custom:member safeTxHash The Safe transaction hash the owners signed.
    /// @custom:member dataHash keccak256 of the signed calldata.
    /// @custom:member signatures The hook's `signatures` argument, byte for byte.
    struct DispatchContext {
        bytes32 safeTxHash;
        Operation operation;
        uint256 value;
        bytes32 dataHash;
        uint256 safeTxGas;
        uint256 baseGas;
        uint256 gasPrice;
        address gasToken;
        address refundReceiver;
        uint256 nonce;
        bytes signatures;
    }

    /// @notice A child Safe's signed `signMessage` approval transaction.
    /// @custom:member signatures The child owners' signatures without the child's policy extension.
    struct ApprovalEvidence {
        address to;
        Operation operation;
        uint256 value;
        bytes data;
        uint256 safeTxGas;
        uint256 baseGas;
        uint256 gasPrice;
        address gasToken;
        address refundReceiver;
        uint256 nonce;
        bytes signatures;
    }

    event ApprovalCached(address indexed childSafe, bytes32 indexed messageHash);

    error NoLiveDispatch(address safe);
    error NotSignedTarget(address caller);
    error AlreadyConsumed(address safe);
    error NestedExecution(address safe);
    error DispatchHashMismatch(bytes32 live, bytes32 txHash);
    error ModuleDispatchDenied();
    error ApprovalNotFound(address childSafe, bytes32 messageHash);

    /// @notice Marks `safe`'s live dispatch consumed and returns it. Only the signed target may call,
    ///         once per dispatch.
    function consume(address safe) external returns (DispatchContext memory context);

    /// @notice The current approval evidence `childSafe` cached for `messageHash`, the hash
    ///         `signMessage` writes into the child's `signedMessages`. Reverts if there is none.
    function getApproval(address childSafe, bytes32 messageHash)
        external
        view
        returns (ApprovalEvidence memory evidence);
}
