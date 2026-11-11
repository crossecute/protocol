// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Safe 1.5.0's `execTransaction`.
interface ISafeExec {
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);
}

/// @title SafeBatchExecutor
/// @notice Runs several separately signed Safe transactions in one outer transaction, all or
///         nothing: the atomic source batch of #108, such as two single-destination sends at
///         consecutive Safe nonces.
/// @dev Each transaction is executed as given, so the caller orders them by nonce; the Safe
///      refuses a nonce out of order. A Safe that returns `false`, which it does for a failed
///      inner call when `safeTxGas` or `gasPrice` is nonzero, reverts the batch like a revert
///      does, so every send and nonce advance in it rolls back. Holds nothing and has no owner,
///      so anyone holding the signatures can submit them.
contract SafeBatchExecutor {
    struct Execution {
        ISafeExec safe;
        address to;
        uint256 value;
        bytes data;
        uint8 operation;
        uint256 safeTxGas;
        uint256 baseGas;
        uint256 gasPrice;
        address gasToken;
        address payable refundReceiver;
        bytes signatures;
    }

    error ExecutionFailed(uint256 index);

    function execute(Execution[] calldata executions) external {
        for (uint256 i = 0; i < executions.length; ++i) {
            Execution calldata e = executions[i];
            // forge-lint: disable-start(calls-loop) one Safe execution per batch entry is the purpose
            bool success = e.safe
                .execTransaction(
                    e.to,
                    e.value,
                    e.data,
                    e.operation,
                    e.safeTxGas,
                    e.baseGas,
                    e.gasPrice,
                    e.gasToken,
                    e.refundReceiver,
                    e.signatures
                );
            // forge-lint: disable-end(calls-loop)
            require(success, ExecutionFailed(i));
        }
    }
}
