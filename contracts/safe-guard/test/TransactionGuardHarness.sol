// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTransactionGuard} from "safe-interface/base/GuardManager.sol";
import {Enum} from "safe-interface/libraries/Enum.sol";
import {GnosisSafe} from "safe-fixture/GnosisSafe.sol";
import {Enum as FixtureEnum} from "safe-fixture/common/Enum.sol";

/// @dev Test-only hook observer. It does not enforce policy or stage signatures.
contract TransactionGuardHarness is BaseTransactionGuard {
    error UnauthorizedSafe();

    address public immutable safe;
    uint256 public preCalls;
    uint256 public postCalls;
    uint256 public signedNonce;
    bytes32 public preDigest;
    bytes32 public postDigest;
    bytes public signatures;
    address public executor;
    bool public success;

    constructor(address safe_) {
        safe = safe_;
    }

    modifier onlySafe() {
        if (msg.sender != safe) revert UnauthorizedSafe();
        _;
    }

    function checkTransaction(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures_,
        address msgSender
    ) external override onlySafe {
        ++preCalls;
        signedNonce = GnosisSafe(payable(safe)).nonce() - 1;
        preDigest = GnosisSafe(payable(safe))
            .getTransactionHash(
                to,
                value,
                data,
                FixtureEnum.Operation(uint8(operation)),
                safeTxGas,
                baseGas,
                gasPrice,
                gasToken,
                refundReceiver,
                signedNonce
            );
        signatures = signatures_;
        executor = msgSender;
    }

    function checkAfterExecution(bytes32 txHash, bool success_) external override onlySafe {
        ++postCalls;
        postDigest = txHash;
        success = success_;
    }
}
