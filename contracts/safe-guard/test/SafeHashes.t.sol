// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {SafeTx} from "../src/ICrossecuteGuard.sol";
import {SafeHashes} from "../src/SafeHashes.sol";
import {GuardTestBase} from "./GuardTestBase.sol";

/// @dev The library must agree with a real Safe 1.5.0 proxy: the guard's post-hook rejects a
///      `sendMessage` whose staged hash differs from the one the Safe computes, and an approval cached
///      under another message hash is never found.
contract SafeHashesTest is GuardTestBase {
    function testFuzz_hash_matchesSafe(SafeTx memory safeTx, uint64 chainId) public {
        safeTx.operation = uint8(bound(safeTx.operation, 0, 1));
        vm.chainId(bound(chainId, 1, type(uint64).max));
        assertEq(SafeHashes.transactionHash(safeTx, address(safe), block.chainid), _safeHash(safeTx));
        assertEq(SafeHashes.domainSeparator(address(safe), block.chainid), safe.domainSeparator());
    }

    function testFuzz_messageHash_matchesSafe(bytes memory message, uint64 chainId) public {
        vm.chainId(bound(chainId, 1, type(uint64).max));
        assertEq(
            SafeHashes.messageHash(message, address(safe), block.chainid), handler.getMessageHashForSafe(safe, message)
        );
    }

    /// @dev Every field is distinct and nonzero, so a swapped or dropped field fails. The policy
    ///      rejects nonzero `safeTxGas` and `gasPrice`, but the hash must match Safe on any input.
    function test_hash_matchesSafeWithSendMessageCalldata() public view {
        SafeTx memory safeTx = SafeTx({
            to: address(transmitter),
            value: 1 ether,
            data: _sendMessageData(),
            operation: uint8(Enum.Operation.DelegateCall),
            safeTxGas: 5,
            baseGas: 7777,
            gasPrice: 6,
            gasToken: address(0xCAFE),
            refundReceiver: address(0xF00D),
            nonce: safe.nonce()
        });
        assertEq(SafeHashes.transactionHash(safeTx, address(safe), block.chainid), _safeHash(safeTx));
    }

    /// @dev The hash scratch space sits past the free memory pointer, so it must leave the struct
    ///      and its calldata intact.
    function test_hash_leavesMemoryIntact() public view {
        SafeTx memory safeTx;
        safeTx.to = address(transmitter);
        safeTx.data = _sendMessageData();
        bytes memory before = abi.encode(safeTx);
        SafeHashes.transactionHash(safeTx, address(safe), block.chainid);
        assertEq(abi.encode(safeTx), before);
    }

    function _safeHash(SafeTx memory t) internal view returns (bytes32) {
        return safe.getTransactionHash(
            t.to,
            t.value,
            t.data,
            Enum.Operation(t.operation),
            t.safeTxGas,
            t.baseGas,
            t.gasPrice,
            t.gasToken,
            payable(t.refundReceiver),
            t.nonce
        );
    }
}
