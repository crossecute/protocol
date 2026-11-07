// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {console2} from "forge-std/console2.sol";
import {SafePolicyGuard} from "policy-engine/SafePolicyGuard.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {GuardTestBase} from "./GuardTestBase.sol";
import {Collider} from "./TestTransmitter.sol";

/// @dev Measures what staging and clearing a dispatch adds to an owner transaction, by blob size.
///      The target never consumes, so the figure is staging plus cleanup. The baseline is the same
///      Safe and policy under an unmodified SafePolicyGuard. Reported in contracts/safe-guard/README.md.
contract DispatchGasTest is GuardTestBase {
    function test_gas_dispatchStaging() public {
        uint256[4] memory sizes = [uint256(0), 1024, 10_240, 102_400];
        for (uint256 i = 0; i < sizes.length; ++i) {
            uint256 withGuard = _dispatchGas(guard, sizes[i]);
            uint256 without = _dispatchGas(new SafePolicyGuard(0, 1 days), sizes[i]);
            console2.log("extension bytes", sizes[i]);
            console2.log("  staging and cleanup", withGuard - without);
            assertGt(withGuard, without);
        }
    }

    function _dispatchGas(SafePolicyGuard guard_, uint256 extension) internal returns (uint256 used) {
        Safe target = _newEoaSafe();
        _install(target, _signers(), guard_, _defaultConfig(), false);
        Collider collider = new Collider();
        bytes memory data = _dispatchData();
        bytes memory sigs = _withPolicyContext(
            _signFor(target, _signers(), address(collider), 0, data, Enum.Operation.Call), new bytes(extension)
        );
        uint256 before = gasleft();
        _execWith(target, address(collider), 0, data, Enum.Operation.Call, sigs);
        used = before - gasleft();
    }
}
