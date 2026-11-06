// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {GnosisSafe} from "safe-fixture/GnosisSafe.sol";
import {GnosisSafeProxy} from "safe-fixture/proxies/GnosisSafeProxy.sol";
import {Enum} from "safe-fixture/common/Enum.sol";
import {TransactionGuardHarness} from "./TransactionGuardHarness.sol";

abstract contract SafeGuardFixture is Test {
    uint256 internal constant OWNER_KEY = 0xa11ce;
    uint256 internal constant GUARD_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;

    GnosisSafe internal safe;
    TransactionGuardHarness internal guard;

    struct SafeTransaction {
        address to;
        uint256 value;
        bytes data;
        Enum.Operation operation;
        uint256 safeTxGas;
        uint256 baseGas;
        uint256 gasPrice;
        address gasToken;
        address payable refundReceiver;
        uint256 nonce;
    }

    function setUp() public virtual {
        GnosisSafe singleton = new GnosisSafe();
        safe = GnosisSafe(payable(address(new GnosisSafeProxy(address(singleton)))));
        address[] memory owners = new address[](1);
        owners[0] = vm.addr(OWNER_KEY);
        safe.setup(owners, 1, address(0), "", address(0), address(0), 0, payable(address(0)));
        guard = new TransactionGuardHarness(address(safe));
        _setGuard(address(guard));
        vm.deal(address(safe), 1 ether);
    }

    function _transaction(address to, bytes memory data) internal view returns (SafeTransaction memory txn) {
        txn.to = to;
        txn.data = data;
        txn.nonce = safe.nonce();
    }

    function _digest(SafeTransaction memory txn) internal view returns (bytes32) {
        return safe.getTransactionHash(
            txn.to,
            txn.value,
            txn.data,
            txn.operation,
            txn.safeTxGas,
            txn.baseGas,
            txn.gasPrice,
            txn.gasToken,
            txn.refundReceiver,
            txn.nonce
        );
    }

    function _sign(SafeTransaction memory txn) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _digest(txn));
        return abi.encodePacked(r, s, v);
    }

    function _execute(SafeTransaction memory txn, bytes memory signatures) internal returns (bool) {
        return safe.execTransaction(
            txn.to,
            txn.value,
            txn.data,
            txn.operation,
            txn.safeTxGas,
            txn.baseGas,
            txn.gasPrice,
            txn.gasToken,
            txn.refundReceiver,
            signatures
        );
    }

    function _setGuard(address next) internal {
        SafeTransaction memory txn = _transaction(address(safe), abi.encodeCall(safe.setGuard, (next)));
        assertTrue(_execute(txn, _sign(txn)));
    }

    function _installedGuard() internal view returns (address) {
        return abi.decode(safe.getStorageAt(GUARD_SLOT, 1), (address));
    }
}
