// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {IERC7786GatewaySource} from "crossecute/messaging/IErc7786.sol";
import {SafePolicyGuard} from "policy-engine/SafePolicyGuard.sol";
import {IERC165} from "policy-engine/interfaces/IERC165.sol";
import {IPolicyEngine} from "policy-engine/interfaces/IPolicyEngine.sol";
import {ISafeModuleGuard} from "policy-engine/interfaces/ISafeModuleGuard.sol";
import {ISafeTransactionGuard} from "policy-engine/interfaces/ISafeTransactionGuard.sol";
import {Operation} from "policy-engine/interfaces/Operation.sol";
import {SignMessageLib} from "safe-smart-account/libraries/SignMessageLib.sol";
import {ISafe} from "safe-smart-account/interfaces/ISafe.sol";
import {ICrossecuteGuard} from "./ICrossecuteGuard.sol";
import {SafeHashes} from "./SafeHashes.sol";

/// @dev The #108 transmitter's owner-facing bootstrap (#120), which has no interface in
///      `contracts/evm` yet. The plain `bootstrap(uint256,Call[],bytes[])` and `bootstrapTo`
///      overloads have other selectors and are not staged.
interface IBootstrap {
    function bootstrap(bytes calldata payload, bytes[] calldata attributes) external payable;
}

/// @title CrossecuteGuard
/// @notice Safe 1.5.0 transaction guard, and optionally module guard, shared by any number of
///         Safes. On top of the inherited policy engine it stages each owner-signed
///         `sendMessage` and `bootstrap` for the signed target to consume, and caches child Safe
///         approvals.
/// @dev Every record is keyed by the hook caller, so a contract that calls the hooks directly
///      can only write and clear records under its own address.
contract CrossecuteGuard is SafePolicyGuard, ICrossecuteGuard {
    /// @dev A Safe's transient record starts at its id, `keccak256(abi.encode(safe, NAMESPACE))`.
    bytes32 internal constant NAMESPACE = keccak256("crossecute.guard.safe");

    // Word offsets from a Safe's id. `_TX_HASH` is nonzero exactly while the record is live.
    uint256 internal constant _TX_HASH = 0;
    uint256 internal constant _TARGET = 1;
    uint256 internal constant _VALUE = 2;
    uint256 internal constant _OPERATION = 3;
    uint256 internal constant _BASE_GAS = 4;
    uint256 internal constant _GAS_TOKEN = 5;
    uint256 internal constant _REFUND_RECEIVER = 6;
    uint256 internal constant _NONCE = 7;
    uint256 internal constant _SIG_LENGTH = 8;
    uint256 internal constant _SIG_WORDS = 9;

    /// @dev Set above the address bits of the `_TARGET` word once the target has consumed.
    uint256 private constant _CONSUMED = 1 << 160;

    // solhint-disable-next-line private-vars-leading-underscore
    mapping(address childSafe => mapping(bytes32 messageHash => SignedSafeTx)) private $approvals;

    constructor(uint256 delay, uint256 expiry) SafePolicyGuard(delay, expiry) {}

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        // SafePolicyGuard's external override is not callable through super.
        return interfaceId == type(ICrossecuteGuard).interfaceId || interfaceId == type(IPolicyEngine).interfaceId
            || interfaceId == type(ISafeModuleGuard).interfaceId
            || interfaceId == type(ISafeTransactionGuard).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc ICrossecuteGuard
    function consume(address safe) external returns (SignedSafeTx memory signedSafeTx) {
        bytes32 safeId = _safeId(safe);
        require(_tload(safeId, _TX_HASH) != 0, NoLiveSendMessage(safe));
        uint256 target = _tload(safeId, _TARGET);
        // forge-lint: disable-next-line(unsafe-typecast) drops the consumed flag above the address
        require(address(uint160(target)) == msg.sender, NotSignedTarget(msg.sender));
        require(target & _CONSUMED == 0, AlreadyConsumed(safe));
        _tstore(safeId, _TARGET, target | _CONSUMED);
        signedSafeTx = _tloadSignedSafeTx(safeId);
    }

    /// @inheritdoc ICrossecuteGuard
    function getApproval(address childSafe, bytes32 messageHash)
        external
        view
        returns (SignedSafeTx memory signedSafeTx)
    {
        signedSafeTx = $approvals[childSafe][messageHash];
        // A Safe threshold is at least one, so stored evidence always carries a signature.
        require(signedSafeTx.signatures.length != 0, ApprovalNotFound(childSafe, messageHash));
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
        bytes32 safeId = _safeId(msg.sender);
        require(_tload(safeId, _TX_HASH) == 0, NestedExecution(msg.sender));

        bytes4 selector = _decodeSelector(data);
        bool staged = _isStaged(selector);
        bool approval = operation == Operation.DELEGATECALL && selector == SignMessageLib.signMessage.selector;
        if (!staged && !approval) return;

        SafeTx memory safeTx = SafeTx({
            to: to,
            value: value,
            data: data,
            operation: uint8(operation),
            safeTxGas: safeTxGas,
            baseGas: baseGas,
            gasPrice: gasPrice,
            gasToken: gasToken,
            refundReceiver: refundReceiver,
            // The Safe increments its nonce before calling the guard.
            nonce: ISafe(payable(msg.sender)).nonce() - 1
        });
        if (staged) {
            _tstoreSignedSafeTx(safeId, safeTx, signatures);
        } else {
            // Recognized by operation and selector alone: Safe has no SignMessageLib allowlist, so
            // the record shows what the owners signed, not what the delegatecall wrote.
            _cacheApproval(
                safeTx, SafeHashes.messageHash(abi.decode(data[4:], (bytes)), msg.sender, block.chainid), signatures
            );
        }
    }

    /// @dev `safeTxGas` and `gasPrice` are not recorded here or in `_cacheApproval`: the inherited
    ///      check has already required both to be zero. The calldata is not recorded: the signed
    ///      target receives it from the Safe's call. The post-hook requires the hash computed here to
    ///      equal the one the Safe passes it, so a disagreement reverts the Safe transaction.
    function _tstoreSignedSafeTx(bytes32 safeId, SafeTx memory safeTx, bytes calldata signatures) private {
        _tstore(safeId, _TX_HASH, uint256(SafeHashes.transactionHash(safeTx, msg.sender, block.chainid)));
        _tstore(safeId, _TARGET, uint160(safeTx.to));
        _tstore(safeId, _VALUE, safeTx.value);
        _tstore(safeId, _OPERATION, safeTx.operation);
        _tstore(safeId, _BASE_GAS, safeTx.baseGas);
        _tstore(safeId, _GAS_TOKEN, uint160(safeTx.gasToken));
        _tstore(safeId, _REFUND_RECEIVER, uint160(safeTx.refundReceiver));
        _tstore(safeId, _NONCE, safeTx.nonce);
        _tstoreSignatures(safeId, signatures);
    }

    function _cacheApproval(SafeTx memory safeTx, bytes32 messageHash, bytes calldata signatures) private {
        SignedSafeTx storage signedSafeTx = $approvals[msg.sender][messageHash];
        SafeTx storage stored = signedSafeTx.safeTx;
        stored.to = safeTx.to;
        stored.value = safeTx.value;
        stored.data = safeTx.data;
        stored.operation = safeTx.operation;
        stored.baseGas = safeTx.baseGas;
        stored.gasToken = safeTx.gasToken;
        stored.refundReceiver = safeTx.refundReceiver;
        stored.nonce = safeTx.nonce;
        signedSafeTx.signatures = _approvalSignatures(signatures);
        // forge-lint: disable-next-line(reentrancy-events) the earlier calls are staticcalls to the caller
        emit ApprovalCached(msg.sender, messageHash);
    }

    /// @dev Safe verified the original blob. Stripping may not remove any threshold entry or
    ///      any length-prefixed contract signature it references, including an empty payload.
    function _approvalSignatures(bytes calldata signatures) private view returns (bytes calldata owners) {
        owners = _ownerSignatures(signatures);
        if (owners.length == signatures.length) return owners;

        uint256 staticLength = ISafe(payable(msg.sender)).getThreshold() * 65;
        require(owners.length >= staticLength, SignatureExtensionOverlap());
        for (uint256 i = 0; i < staticLength; i += 65) {
            if (owners[i + 64] != 0) continue;
            uint256 offset = uint256(bytes32(owners[i + 32:i + 64]));
            require(offset <= owners.length - 32, SignatureExtensionOverlap());
            uint256 length = uint256(bytes32(owners[offset:offset + 32]));
            require(length <= owners.length - offset - 32, SignatureExtensionOverlap());
        }
    }

    function _afterOwnerExecution(bytes32 txHash) internal override {
        bytes32 safeId = _safeId(msg.sender);
        bytes32 live = bytes32(_tload(safeId, _TX_HASH));
        if (live == 0) return;
        require(live == txHash, HashMismatch(live, txHash));

        uint256 words = (_tload(safeId, _SIG_LENGTH) + 31) >> 5;
        for (uint256 i = 0; i < _SIG_WORDS + words; ++i) {
            _tstore(safeId, i, 0);
        }
    }

    /// @dev Runs after the inherited policy check, so this only narrows what policy permits.
    function _afterModulePolicyCheck(address, uint256, bytes calldata data, Operation, address) internal pure override {
        require(!_isStaged(_decodeSelector(data)), ModuleSendMessageDenied());
    }

    /// @dev The selectors whose owner transactions are staged and whose module transactions are
    ///      rejected. Each is matched by selector alone, whatever the target.
    function _isStaged(bytes4 selector) private pure returns (bool) {
        return selector == IERC7786GatewaySource.sendMessage.selector || selector == IBootstrap.bootstrap.selector;
    }

    function _tloadSignedSafeTx(bytes32 safeId) private view returns (SignedSafeTx memory signedSafeTx) {
        SafeTx memory safeTx = signedSafeTx.safeTx;
        // forge-lint: disable-next-line(unsafe-typecast) drops the consumed flag above the address
        safeTx.to = address(uint160(_tload(safeId, _TARGET)));
        safeTx.value = _tload(safeId, _VALUE);
        // forge-lint: disable-next-line(unsafe-typecast) written from an Operation
        safeTx.operation = uint8(_tload(safeId, _OPERATION));
        safeTx.baseGas = _tload(safeId, _BASE_GAS);
        // forge-lint: disable-next-line(unsafe-typecast) written from an address
        safeTx.gasToken = address(uint160(_tload(safeId, _GAS_TOKEN)));
        // forge-lint: disable-next-line(unsafe-typecast) written from an address
        safeTx.refundReceiver = address(uint160(_tload(safeId, _REFUND_RECEIVER)));
        safeTx.nonce = _tload(safeId, _NONCE);

        uint256 length = _tload(safeId, _SIG_LENGTH);
        bytes memory signatures = new bytes(length);
        for (uint256 i = 0; i < length; i += 32) {
            uint256 word = _tload(safeId, _SIG_WORDS + (i >> 5));
            assembly ("memory-safe") {
                mstore(add(add(signatures, 0x20), i), word)
            }
        }
        signedSafeTx.signatures = signatures;
    }

    /// @dev The final word is masked to `signatures`' length so the record holds no calldata past it.
    function _tstoreSignatures(bytes32 safeId, bytes calldata signatures) private {
        uint256 length = signatures.length;
        _tstore(safeId, _SIG_LENGTH, length);
        for (uint256 i = 0; i < length; i += 32) {
            uint256 word;
            assembly ("memory-safe") {
                word := calldataload(add(signatures.offset, i))
            }
            uint256 remaining = length - i;
            if (remaining < 32) {
                word &= ~(type(uint256).max >> (remaining << 3));
            }
            _tstore(safeId, _SIG_WORDS + (i >> 5), word);
        }
    }

    function _safeId(address safe) internal pure returns (bytes32) {
        return keccak256(abi.encode(safe, NAMESPACE));
    }

    function _tload(bytes32 safeId, uint256 offset) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(add(safeId, offset))
        }
    }

    function _tstore(bytes32 safeId, uint256 offset, uint256 value) private {
        assembly ("memory-safe") {
            tstore(add(safeId, offset), value)
        }
    }
}
