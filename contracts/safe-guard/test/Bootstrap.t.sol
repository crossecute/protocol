// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Call} from "crossecute/messaging/Call.sol";
import {SafePolicyGuard} from "policy-engine/SafePolicyGuard.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {ISignedTransmitter} from "crossecute/messaging/outbound/ISignedTransmitter.sol";
import {ICrossecuteGuard} from "../src/ICrossecuteGuard.sol";
import {ModuleTest} from "./Module.t.sol";
import {SendMessageTest} from "./SendMessage.t.sol";
import {IPlainBootstrap} from "./TestTransmitter.sol";

function plainBootstrapData() pure returns (bytes memory) {
    return abi.encodeCall(IPlainBootstrap.bootstrap, (1, new Call[](0), new bytes[](0)));
}

/// @dev The owner lifecycle tests with `bootstrap(bytes,bytes[])` as the staged selector.
contract BootstrapTest is SendMessageTest {
    function _stagedData() internal pure override returns (bytes memory) {
        return _bootstrapData();
    }

    function test_transmitterUsesBootstrapSelector() public pure {
        assertEq(bytes4(_bootstrapData()), ISignedTransmitter.bootstrap.selector);
        assertTrue(IPlainBootstrap.bootstrap.selector != ISignedTransmitter.bootstrap.selector);
    }

    function test_plainBootstrap_notStaged() public {
        bytes memory data = plainBootstrapData();
        bytes memory sigs = _signFor(safe, _signers(), address(transmitter), 0, data, Enum.Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.NoLiveRecord.selector, address(safe)));
        _execWith(safe, address(transmitter), 0, data, Enum.Operation.Call, sigs);
    }

    function test_sendMessageThenBootstrap_independentRecords() public {
        uint256 nonce = safe.nonce();
        _run(
            _execCall(safe, _signers(), address(transmitter), 0, _sendMessageData(), Enum.Operation.Call, nonce),
            _execCall(safe, _signers(), address(transmitter), 0, _bootstrapData(), Enum.Operation.Call, nonce + 1),
            _cleared(safe, 8)
        );
        assertEq(transmitter.sends(), 2);
        assertEq(
            transmitter.lastSafeTxHash(),
            _txHashAt(safe, address(transmitter), 0, _bootstrapData(), Enum.Operation.Call, nonce + 1)
        );
    }
}

/// @dev The module guard tests with `bootstrap(bytes,bytes[])` as the staged selector.
contract ModuleBootstrapTest is ModuleTest {
    function _stagedData() internal pure override returns (bytes memory) {
        return _bootstrapData();
    }

    /// @dev Policy permits the module's plain bootstrap, and the module callback lets it through.
    ///      The transmitter then finds nothing staged, and the module post-hook reports the failure.
    function test_modulePlainBootstrap_notDeniedOrStaged() public {
        vm.expectCall(address(guard), abi.encodeCall(ICrossecuteGuard.consume, (address(guarded))));
        vm.expectRevert(SafePolicyGuard.ModuleExecutionFailed.selector);
        module.execStrict(guarded, address(guardedTransmitter), plainBootstrapData(), Enum.Operation.Call);
    }
}
