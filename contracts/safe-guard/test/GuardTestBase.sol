// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {SafePolicyGuard} from "policy-engine/SafePolicyGuard.sol";
import {Operation} from "policy-engine/interfaces/Operation.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {SignMessageLib} from "safe-smart-account/libraries/SignMessageLib.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {IBootstrap} from "../src/CrossecuteGuard.sol";
import {Batch} from "./Batch.sol";
import {SafeFixture} from "./SafeFixture.sol";
import {Sink, TestTransmitter} from "./TestTransmitter.sol";

/// @dev A 2-of-3 EOA Safe with the guard installed in its transaction guard slot and a
///      transmitter it owns. Tests that depend on transient state across executions run them in
///      one `Batch`, with the cleanup probe as a later call in the same batch.
abstract contract GuardTestBase is SafeFixture {
    uint256 internal constant KEY_A = 0xA11CE;
    uint256 internal constant KEY_B = 0xB0B;
    uint256 internal constant KEY_C = 0xC4A5;

    Safe internal safe;
    Sink internal sink;
    TestTransmitter internal transmitter;
    Batch internal batch;

    function setUp() public virtual override {
        super.setUp();
        batch = new Batch();
        sink = new Sink();
        safe = _newEoaSafe();
        transmitter = new TestTransmitter(address(safe), sink);
        _install(safe, _signers(), guard, _defaultConfig(), false);
        vm.deal(address(safe), 10 ether);
    }

    function _newEoaSafe() internal returns (Safe) {
        address[] memory owners = new address[](3);
        owners[0] = vm.addr(KEY_A);
        owners[1] = vm.addr(KEY_B);
        owners[2] = vm.addr(KEY_C);
        return _newSafe(owners, 2);
    }

    function _signers() internal pure returns (Signer[] memory signers) {
        signers = new Signer[](2);
        signers[0] = _eoa(KEY_A);
        signers[1] = _eoa(KEY_B);
    }

    /// @dev Owner-side policy only: any CALL, and the two delegatecall targets the tests use.
    function _defaultConfig() internal view returns (SafePolicyGuard.Configuration[] memory configs) {
        configs = new SafePolicyGuard.Configuration[](3);
        configs[0] = _config(address(0), bytes4(0), Operation.CALL, address(allowPolicy));
        configs[1] =
            _config(address(multiSend), multiSend.multiSend.selector, Operation.DELEGATECALL, address(allowPolicy));
        configs[2] = _config(
            address(signMessageLib), SignMessageLib.signMessage.selector, Operation.DELEGATECALL, address(allowPolicy)
        );
    }

    function _sendMessageData() internal pure returns (bytes memory) {
        return abi.encodeCall(TestTransmitter.sendMessage, (hex"01", hex"02", new bytes[](0)));
    }

    function _bootstrapData() internal pure returns (bytes memory) {
        return abi.encodeCall(IBootstrap.bootstrap, (hex"01", new bytes[](0)));
    }

    /// @dev The staged calldata the shared lifecycle tests sign. Suites rerun them by overriding it.
    function _stagedData() internal pure virtual returns (bytes memory) {
        return _sendMessageData();
    }

    /// @dev An `execTransaction` call signed for an explicit nonce, for use inside a batch.
    function _execCall(
        Safe safe_,
        Signer[] memory signers,
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation op,
        uint256 nonce
    ) internal view returns (Batch.Call memory) {
        return _execCallWith(safe_, to, value, data, op, _sign(signers, _txHashAt(safe_, to, value, data, op, nonce)));
    }

    function _execCallWith(
        Safe safe_,
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation op,
        bytes memory signatures
    ) internal pure returns (Batch.Call memory) {
        return Batch.Call(address(safe_), _execData(to, value, data, op, signatures), false);
    }

    function _execData(address to, uint256 value, bytes memory data, Enum.Operation op, bytes memory signatures)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(
            Safe.execTransaction, (to, value, data, op, 0, 0, 0, address(0), payable(address(0)), signatures)
        );
    }

    /// @dev Reverts the batch unless `safe_`'s record is zero, including `signatureWords` words.
    function _cleared(Safe safe_, uint256 signatureWords) internal view returns (Batch.Call memory) {
        return Batch.Call(address(guard), abi.encodeCall(guard.requireCleared, (address(safe_), signatureWords)), false);
    }

    function _run(Batch.Call memory a, Batch.Call memory b) internal returns (bytes[] memory) {
        Batch.Call[] memory calls = new Batch.Call[](2);
        (calls[0], calls[1]) = (a, b);
        return batch.run(calls);
    }

    function _run(Batch.Call memory a, Batch.Call memory b, Batch.Call memory c) internal returns (bytes[] memory) {
        Batch.Call[] memory calls = new Batch.Call[](3);
        (calls[0], calls[1], calls[2]) = (a, b, c);
        return batch.run(calls);
    }

    function _run(Batch.Call memory a, Batch.Call memory b, Batch.Call memory c, Batch.Call memory d)
        internal
        returns (bytes[] memory)
    {
        Batch.Call[] memory calls = new Batch.Call[](4);
        (calls[0], calls[1], calls[2], calls[3]) = (a, b, c, d);
        return batch.run(calls);
    }
}
