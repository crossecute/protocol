// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {IERC7786GatewaySource} from "crossecute/messaging/IErc7786.sol";
import {SafePolicyGuard} from "policy-engine/SafePolicyGuard.sol";
import {Operation} from "policy-engine/interfaces/Operation.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {SignMessageLib} from "safe-smart-account/libraries/SignMessageLib.sol";
import {ISafe} from "safe-smart-account/interfaces/ISafe.sol";
import {ICrossecuteGuard} from "./ICrossecuteGuard.sol";

/// @title CrossecuteGuard
/// @notice Safe 1.5.0 transaction guard, and optionally module guard, shared by any number of
///         Safes. On top of the inherited policy engine it stages each owner-signed
///         `sendMessage` for the signed target to consume, and caches child Safe approvals.
/// @dev Every record is keyed by the hook caller, so a contract that calls the hooks directly
///      can only write and clear records under its own address.
contract CrossecuteGuard is SafePolicyGuard, ICrossecuteGuard {
    /// @dev Safe's `SAFE_MSG_TYPEHASH`, `keccak256("SafeMessage(bytes message)")`.
    bytes32 private constant _SAFE_MSG_TYPEHASH = 0x60b3cbf8b4a223d68d641b3b6ddf9a298e7f33710cf3d3a9d1146b5a6150fbca;

    /// @dev A Safe's transient dispatch record starts at `keccak256(abi.encode(safe, namespace))`.
    bytes32 internal constant _DISPATCH_NAMESPACE = keccak256("crossecute.guard.dispatch.v1");

    // Word offsets from a record's base. `_TX_HASH` is nonzero exactly while the record is live.
    uint256 internal constant _TX_HASH = 0;
    uint256 internal constant _TARGET = 1;
    uint256 internal constant _OPERATION = 2;
    uint256 internal constant _VALUE = 3;
    uint256 internal constant _DATA_HASH = 4;
    uint256 internal constant _BASE_GAS = 5;
    uint256 internal constant _GAS_TOKEN = 6;
    uint256 internal constant _REFUND_RECEIVER = 7;
    uint256 internal constant _NONCE = 8;
    uint256 internal constant _SIG_LENGTH = 9;
    uint256 internal constant _SIG_WORDS = 10;

    /// @dev Set above the address bits of the `_TARGET` word once the target has consumed.
    uint256 private constant _CONSUMED = 1 << 160;

    // solhint-disable-next-line private-vars-leading-underscore
    mapping(address childSafe => mapping(bytes32 messageHash => ApprovalEvidence)) private $approvals;

    constructor(uint256 delay, uint256 expiry) SafePolicyGuard(delay, expiry) {}

    /// @inheritdoc ICrossecuteGuard
    function consume(address safe) external returns (DispatchContext memory context) {
        bytes32 base = _dispatchBase(safe);
        bytes32 txHash = bytes32(_tload(base, _TX_HASH));
        require(txHash != 0, NoLiveDispatch(safe));
        uint256 target = _tload(base, _TARGET);
        // forge-lint: disable-next-line(unsafe-typecast) drops the consumed flag above the address
        require(address(uint160(target)) == msg.sender, NotSignedTarget(msg.sender));
        require(target & _CONSUMED == 0, AlreadyConsumed(safe));
        _tstore(base, _TARGET, target | _CONSUMED);
        context = _readDispatch(base, txHash);
    }

    /// @inheritdoc ICrossecuteGuard
    function getApproval(address childSafe, bytes32 messageHash)
        external
        view
        returns (ApprovalEvidence memory evidence)
    {
        evidence = $approvals[childSafe][messageHash];
        // A Safe threshold is at least one, so stored evidence always carries a signature.
        require(evidence.signatures.length != 0, ApprovalNotFound(childSafe, messageHash));
    }

    /// @dev Same-Safe nesting is rejected for the whole life of a record, so the next post-hook from
    ///      this Safe belongs to the execution that staged it. `safeTxGas` and `gasPrice` are not
    ///      recorded: the inherited check has already required both to be zero.
    function _afterOwnerPolicyCheck(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures,
        address
    ) internal override {
        bytes32 base = _dispatchBase(msg.sender);
        require(_tload(base, _TX_HASH) == 0, NestedExecution(msg.sender));

        bytes4 selector = _decodeSelector(data);
        bool dispatch = selector == IERC7786GatewaySource.sendMessage.selector;
        bool approval = operation == Operation.DELEGATECALL && selector == SignMessageLib.signMessage.selector;
        if (!dispatch && !approval) return;

        // The Safe increments its nonce before calling the guard.
        uint256 nonce = ISafe(payable(msg.sender)).nonce() - 1;
        if (dispatch) {
            bytes32 txHash = ISafe(payable(msg.sender))
                .getTransactionHash(
                    to,
                    value,
                    data,
                    Enum.Operation(uint8(operation)),
                    safeTxGas,
                    baseGas,
                    gasPrice,
                    gasToken,
                    refundReceiver,
                    nonce
                );
            _tstore(base, _TX_HASH, uint256(txHash));
            _tstore(base, _TARGET, uint160(to));
            _tstore(base, _OPERATION, uint8(operation));
            _tstore(base, _VALUE, value);
            _tstore(base, _DATA_HASH, uint256(keccak256(data)));
            _tstore(base, _BASE_GAS, baseGas);
            _tstore(base, _GAS_TOKEN, uint160(gasToken));
            _tstore(base, _REFUND_RECEIVER, uint160(address(refundReceiver)));
            _tstore(base, _NONCE, nonce);
            _stageSignatures(base, signatures);
        } else {
            // Recognized by operation and selector alone: Safe has no SignMessageLib allowlist, so
            // the record shows what the owners signed, not what the delegatecall wrote.
            bytes32 messageHash = _safeMessageHash(abi.decode(data[4:], (bytes)));
            ApprovalEvidence storage evidence = $approvals[msg.sender][messageHash];
            evidence.to = to;
            evidence.operation = uint8(operation);
            evidence.value = value;
            evidence.data = data;
            evidence.baseGas = baseGas;
            evidence.gasToken = gasToken;
            evidence.refundReceiver = refundReceiver;
            evidence.nonce = nonce;
            evidence.signatures = _ownerSignatures(signatures);
            // forge-lint: disable-next-line(reentrancy-events) the earlier calls are staticcalls to the caller
            emit ApprovalCached(msg.sender, messageHash);
        }
    }

    function _afterOwnerExecution(bytes32 txHash) internal override {
        bytes32 base = _dispatchBase(msg.sender);
        bytes32 live = bytes32(_tload(base, _TX_HASH));
        if (live == 0) return;
        require(live == txHash, DispatchHashMismatch(live, txHash));

        uint256 words = (_tload(base, _SIG_LENGTH) + 31) >> 5;
        for (uint256 i = 0; i < _SIG_WORDS + words; ++i) {
            _tstore(base, i, 0);
        }
    }

    /// @dev Runs after the inherited policy check, so this only narrows what policy permits.
    function _afterModulePolicyCheck(address, uint256, bytes calldata data, Operation, address) internal pure override {
        require(_decodeSelector(data) != IERC7786GatewaySource.sendMessage.selector, ModuleDispatchDenied());
    }

    function _readDispatch(bytes32 base, bytes32 txHash) private view returns (DispatchContext memory context) {
        context.safeTxHash = txHash;
        // forge-lint: disable-next-line(unsafe-typecast) written from an Operation
        context.operation = uint8(_tload(base, _OPERATION));
        context.value = _tload(base, _VALUE);
        context.dataHash = bytes32(_tload(base, _DATA_HASH));
        context.baseGas = _tload(base, _BASE_GAS);
        // forge-lint: disable-next-line(unsafe-typecast) written from an address
        context.gasToken = address(uint160(_tload(base, _GAS_TOKEN)));
        // forge-lint: disable-next-line(unsafe-typecast) written from an address
        context.refundReceiver = address(uint160(_tload(base, _REFUND_RECEIVER)));
        context.nonce = _tload(base, _NONCE);

        uint256 length = _tload(base, _SIG_LENGTH);
        bytes memory signatures = new bytes(length);
        for (uint256 i = 0; i < length; i += 32) {
            uint256 word = _tload(base, _SIG_WORDS + (i >> 5));
            assembly ("memory-safe") {
                mstore(add(add(signatures, 0x20), i), word)
            }
        }
        context.signatures = signatures;
    }

    /// @dev The final word is masked to `signatures`' length so the record holds no calldata past it.
    function _stageSignatures(bytes32 base, bytes calldata signatures) private {
        uint256 length = signatures.length;
        _tstore(base, _SIG_LENGTH, length);
        for (uint256 i = 0; i < length; i += 32) {
            uint256 word;
            assembly ("memory-safe") {
                word := calldataload(add(signatures.offset, i))
            }
            uint256 remaining = length - i;
            if (remaining < 32) {
                word &= ~(type(uint256).max >> (remaining << 3));
            }
            _tstore(base, _SIG_WORDS + (i >> 5), word);
        }
    }

    /// @dev The hash `SignMessageLib.signMessage(message)` writes when delegatecalled by the caller.
    function _safeMessageHash(bytes memory message) private view returns (bytes32) {
        bytes32 safeMessageHash = keccak256(abi.encode(_SAFE_MSG_TYPEHASH, keccak256(message)));
        return keccak256(
            abi.encodePacked(bytes1(0x19), bytes1(0x01), ISafe(payable(msg.sender)).domainSeparator(), safeMessageHash)
        );
    }

    function _dispatchBase(address safe) internal pure returns (bytes32) {
        return keccak256(abi.encode(safe, _DISPATCH_NAMESPACE));
    }

    function _tload(bytes32 base, uint256 offset) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(add(base, offset))
        }
    }

    function _tstore(bytes32 base, uint256 offset, uint256 value) private {
        assembly ("memory-safe") {
            tstore(add(base, offset), value)
        }
    }
}
