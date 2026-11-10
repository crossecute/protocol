// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {console2} from "forge-std/console2.sol";
import {SafePolicyGuard} from "policy-engine/SafePolicyGuard.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {SignMessageLib} from "safe-smart-account/libraries/SignMessageLib.sol";
import {GuardTestBase} from "./GuardTestBase.sol";

/// @dev Measures what caching one approval adds to the child's `signMessage` execution, for the
///      two child shapes in docs/safe-approval-evidence-sizing.md. The baseline is the same Safe
///      and policy under an unmodified SafePolicyGuard.
contract ApprovalGasTest is GuardTestBase {
    function test_gas_approvalCache_10of13() public {
        _measure(13, 10);
    }

    function test_gas_approvalCache_5of7() public {
        _measure(7, 5);
    }

    function _measure(uint256 owners, uint256 threshold) internal {
        (uint256 withCache, uint256 encoded) = _approvalGas(guard, owners, threshold);
        (uint256 without,) = _approvalGas(new SafePolicyGuard(0, 1 days), owners, threshold);
        console2.log("threshold", threshold);
        console2.log("  approval gas with cache", withCache);
        console2.log("  approval gas without cache", without);
        console2.log("  cache cost", withCache - without);
        console2.log("  getApproval ABI bytes", encoded);
        assertGt(withCache, without);
    }

    function _approvalGas(SafePolicyGuard guard_, uint256 ownerCount, uint256 threshold)
        internal
        returns (uint256 used, uint256 encoded)
    {
        address[] memory owners = new address[](ownerCount);
        Signer[] memory signers = new Signer[](threshold);
        for (uint256 i = 0; i < ownerCount; ++i) {
            owners[i] = vm.addr(0x1000 + i);
            if (i < threshold) signers[i] = _eoa(0x1000 + i);
        }
        Safe child = _newSafe(owners, threshold);
        _install(child, signers, guard_, _defaultConfig(), false);

        // Safe 1.5.0 asks a contract owner to validate `abi.encode(parentTxHash)`: 100 bytes of calldata.
        bytes memory data = abi.encodeCall(SignMessageLib.signMessage, (abi.encode(keccak256("parent"))));
        bytes memory sigs = _signFor(child, signers, address(signMessageLib), 0, data, Enum.Operation.DelegateCall);
        uint256 before = gasleft();
        _execWith(child, address(signMessageLib), 0, data, Enum.Operation.DelegateCall, sigs);
        used = before - gasleft();
        if (address(guard_) == address(guard)) {
            bytes32 messageHash = handler.getMessageHashForSafe(child, abi.encode(keccak256("parent")));
            encoded = abi.encode(guard.getApproval(address(child), messageHash)).length;
        }
    }
}
