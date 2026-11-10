// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {ISafe} from "safe-smart-account/interfaces/ISafe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {IRootRegistration} from "../src/CrossecuteGuard.sol";
import {GuardDiscovery} from "../src/GuardDiscovery.sol";
import {ICrossecuteGuard} from "../src/ICrossecuteGuard.sol";
import {CrossecuteGuardHarness} from "./CrossecuteGuardHarness.sol";

/// @dev Stands in for an external effect. Records whether the caller's sendMessage record was already
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
contract TestTransmitter is IRootRegistration {
    enum Mode {
        Consume,
        Skip,
        ConsumeTwice,
        ConsumeThenRevert,
        CallThenConsume,
        ConsumeThenCall
    }

    struct ApprovalRef {
        address childSafe;
        bytes32 messageHash;
    }

    error NotOwner();
    error Reverted();

    address public immutable OWNER;
    Sink public immutable SINK;

    Mode public mode;
    address public callTarget;
    bytes public callData;
    ApprovalRef[] public approvals;

    uint256 public sends;
    bytes32 public lastSafeTxHash;
    bytes public lastSignatures;
    uint256 public lastValue;
    /// @dev `abi.encode` of the last consumed record, as the guard returned it.
    bytes public lastSendMessage;
    uint256[] public lastApprovalNonces;
    uint256 public registrations;
    bytes32 public lastRoot;
    /// @dev Whether the guard held a live record for the owner during the last registration.
    bool public stagedDuringRegistration;

    constructor(address owner, Sink sink) {
        OWNER = owner;
        SINK = sink;
    }

    function setMode(Mode mode_, address callTarget_, bytes calldata callData_) external {
        mode = mode_;
        callTarget = callTarget_;
        callData = callData_;
    }

    function attachApproval(address childSafe, bytes32 messageHash) external {
        approvals.push(ApprovalRef(childSafe, messageHash));
    }

    function sendMessage(bytes calldata, bytes calldata, bytes[] calldata) external payable returns (bytes32) {
        require(msg.sender == OWNER, NotOwner());
        ++sends;
        if (mode == Mode.Skip) return 0;

        if (mode == Mode.CallThenConsume) _call();
        ICrossecuteGuard guard = ICrossecuteGuard(GuardDiscovery.transactionGuard(msg.sender));
        ICrossecuteGuard.SignedSafeTx memory signedSafeTx = guard.consume(msg.sender);
        lastSendMessage = abi.encode(signedSafeTx);
        signedSafeTx.safeTx.data = msg.data;
        lastSafeTxHash = _safeTxHash(signedSafeTx.safeTx);
        lastSignatures = signedSafeTx.signatures;
        lastValue = msg.value;

        if (mode == Mode.ConsumeTwice) guard.consume(msg.sender);
        if (mode == Mode.ConsumeThenRevert) revert Reverted();
        if (mode == Mode.ConsumeThenCall) _call();

        delete lastApprovalNonces;
        for (uint256 i = 0; i < approvals.length; ++i) {
            lastApprovalNonces.push(guard.getApproval(approvals[i].childSafe, approvals[i].messageHash).safeTx.nonce);
        }

        SINK.hit{value: msg.value}(CrossecuteGuardHarness(address(guard)), msg.sender);
        return lastSafeTxHash;
    }

    /// @dev Records the root as #108's transmitter would. A relayer supplies the signatures later.
    function registerRoot(bytes32 root) external {
        require(msg.sender == OWNER, NotOwner());
        CrossecuteGuardHarness guard = CrossecuteGuardHarness(GuardDiscovery.transactionGuard(msg.sender));
        stagedDuringRegistration = guard.recordWords(msg.sender, 0)[0] != 0;
        lastRoot = root;
        ++registrations;
    }

    function _safeTxHash(ICrossecuteGuard.SafeTx memory t) private view returns (bytes32) {
        return ISafe(payable(OWNER))
            .getTransactionHash(
                t.to,
                t.value,
                t.data,
                Enum.Operation(t.operation),
                t.safeTxGas,
                t.baseGas,
                t.gasPrice,
                t.gasToken,
                t.refundReceiver,
                t.nonce
            );
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

/// @dev Has the `sendMessage` selector and no relation to the guard.
contract Collider {
    uint256 public calls;

    function sendMessage(bytes calldata, bytes calldata, bytes[] calldata) external payable returns (bytes32) {
        ++calls;
        return 0;
    }
}

/// @dev Has the `registerRoot` selector and no relation to the guard.
contract RootCollider is IRootRegistration {
    uint256 public calls;

    function registerRoot(bytes32) external {
        ++calls;
    }
}

/// @dev Tries to consume another Safe's record.
contract Thief {
    function steal(ICrossecuteGuard guard, address safe) external {
        guard.consume(safe);
    }
}
