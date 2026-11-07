// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {GuardDiscovery} from "../src/GuardDiscovery.sol";
import {ICrossecuteGuard} from "../src/ICrossecuteGuard.sol";
import {CrossecuteGuardHarness} from "./CrossecuteGuardHarness.sol";

/// @dev Stands in for an external effect. Records whether the caller's dispatch was already
///      consumed when the effect ran.
contract Sink {
    uint256 public calls;
    bool public consumedFirst;

    function hit(CrossecuteGuardHarness guard, address safe) external payable {
        ++calls;
        consumedFirst = guard.recordWords(safe, 0)[1] >> 160 == 1;
    }
}

/// @dev Minimal signature-enabled transmitter: authenticates its owner Safe, discovers the guard,
///      consumes before any other external call, and sends nothing over a bridge. The modes exist
///      to drive the guard's failure paths.
contract TestTransmitter {
    enum Mode {
        Consume,
        Skip,
        ConsumeTwice,
        ConsumeThenRevert,
        CallThenConsume,
        ConsumeThenCall
    }

    error NotOwner();
    error Reverted();

    address public immutable OWNER;
    Sink public immutable SINK;

    Mode public mode;
    address public callTarget;
    bytes public callData;

    uint256 public sends;
    bytes32 public lastSafeTxHash;
    bytes public lastSignatures;
    uint256 public lastValue;

    constructor(address owner, Sink sink) {
        OWNER = owner;
        SINK = sink;
    }

    function setMode(Mode mode_, address callTarget_, bytes calldata callData_) external {
        mode = mode_;
        callTarget = callTarget_;
        callData = callData_;
    }

    function sendMessage(bytes calldata, bytes calldata, bytes[] calldata) external payable returns (bytes32) {
        require(msg.sender == OWNER, NotOwner());
        ++sends;
        if (mode == Mode.Skip) return 0;

        if (mode == Mode.CallThenConsume) _call();
        ICrossecuteGuard guard = ICrossecuteGuard(GuardDiscovery.transactionGuard(msg.sender));
        ICrossecuteGuard.DispatchContext memory context = guard.consume(msg.sender);
        lastSafeTxHash = context.safeTxHash;
        lastSignatures = context.signatures;
        lastValue = msg.value;

        if (mode == Mode.ConsumeTwice) guard.consume(msg.sender);
        if (mode == Mode.ConsumeThenRevert) revert Reverted();
        if (mode == Mode.ConsumeThenCall) _call();

        SINK.hit{value: msg.value}(CrossecuteGuardHarness(address(guard)), msg.sender);
        return context.safeTxHash;
    }

    function _call() private {
        (bool success, bytes memory reason) = callTarget.call(callData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }
}

/// @dev Has the dispatch selector and no relation to the guard.
contract Collider {
    uint256 public calls;

    function sendMessage(bytes calldata, bytes calldata, bytes[] calldata) external payable returns (bytes32) {
        ++calls;
        return 0;
    }
}

/// @dev Tries to consume another Safe's record.
contract Thief {
    function steal(ICrossecuteGuard guard, address safe) external {
        guard.consume(safe);
    }
}
