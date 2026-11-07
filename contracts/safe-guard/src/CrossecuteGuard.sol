// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {IERC7786GatewaySource} from "crossecute/messaging/IErc7786.sol";
import {SafePolicyGuard} from "policy-engine/SafePolicyGuard.sol";
import {Operation} from "policy-engine/interfaces/Operation.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {ISafe} from "safe-smart-account/interfaces/ISafe.sol";
import {ICrossecuteGuard} from "./ICrossecuteGuard.sol";

/// @title CrossecuteGuard
/// @notice Safe 1.5.0 transaction guard, and optionally module guard, shared by any number of
///         Safes. On top of the inherited policy engine it stages each owner-signed
///         `sendMessage` for the signed target to consume.
/// @dev Every record is keyed by the hook caller, so a contract that calls the hooks directly
///      can only write and clear records under its own address.
contract CrossecuteGuard is SafePolicyGuard, ICrossecuteGuard {
    /// @dev A Safe's transient dispatch record starts at `keccak256(abi.encode(safe, namespace))`.
    bytes32 internal constant _DISPATCH_NAMESPACE = keccak256("crossecute.guard.dispatch.v1");

    // Word offsets from a record's base. `_TX_HASH` is nonzero exactly while the record is live.
    uint256 internal constant _TX_HASH = 0;
    uint256 internal constant _TARGET = 1;
    uint256 internal constant _OPERATION = 2;
    uint256 internal constant _VALUE = 3;
    uint256 internal constant _DATA_HASH = 4;
    uint256 internal constant _SAFE_TX_GAS = 5;
    uint256 internal constant _BASE_GAS = 6;
    uint256 internal constant _GAS_PRICE = 7;
    uint256 internal constant _GAS_TOKEN = 8;
    uint256 internal constant _REFUND_RECEIVER = 9;
    uint256 internal constant _NONCE = 10;
    uint256 internal constant _SIG_LENGTH = 11;
    uint256 internal constant _SIG_WORDS = 12;

    /// @dev Set above the address bits of the `_TARGET` word once the target has consumed.
    uint256 private constant _CONSUMED = 1 << 160;

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

    /// @dev Same-Safe nesting is rejected for the whole life of a record, so the next post-hook from
    ///      this Safe belongs to the execution that staged it.
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

        if (_decodeSelector(data) != IERC7786GatewaySource.sendMessage.selector) return;

        // The Safe increments its nonce before calling the guard.
        uint256 nonce = ISafe(payable(msg.sender)).nonce() - 1;
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
        _tstore(base, _SAFE_TX_GAS, safeTxGas);
        _tstore(base, _BASE_GAS, baseGas);
        _tstore(base, _GAS_PRICE, gasPrice);
        _tstore(base, _GAS_TOKEN, uint160(gasToken));
        _tstore(base, _REFUND_RECEIVER, uint160(address(refundReceiver)));
        _tstore(base, _NONCE, nonce);
        _stageSignatures(base, signatures);
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
        context.operation = Operation(_tload(base, _OPERATION));
        context.value = _tload(base, _VALUE);
        context.dataHash = bytes32(_tload(base, _DATA_HASH));
        context.safeTxGas = _tload(base, _SAFE_TX_GAS);
        context.baseGas = _tload(base, _BASE_GAS);
        context.gasPrice = _tload(base, _GAS_PRICE);
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
