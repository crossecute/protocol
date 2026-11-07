// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice What a transmitter consumes from the guard, and what a relayer reads from it.
/// @dev Free of policy-engine imports so the protocol's 0.8.28 transmitters can import it. Each
///      `operation` is Safe's `Enum.Operation` as a `uint8`: 0 for CALL, 1 for DELEGATECALL.
interface ICrossecuteGuard {
    /// @notice A Safe's staged dispatch: the signed transaction and its complete signature blob.
    /// @custom:member safeTxHash The Safe transaction hash the owners signed.
    /// @custom:member dataHash keccak256 of the signed calldata.
    /// @custom:member signatures The hook's `signatures` argument, byte for byte. Safe checks only the
    ///                first threshold-many signatures; anything after them, the policy extension
    ///                included, is as the submitter sent it.
    struct DispatchContext {
        bytes32 safeTxHash;
        uint8 operation;
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
        uint8 operation;
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
