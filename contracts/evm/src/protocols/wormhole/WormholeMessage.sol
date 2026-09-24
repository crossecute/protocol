// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICoreBridge, CoreBridgeVM} from "@wormhole-sdk/interfaces/ICoreBridge.sol";
import {IExecutorQuoterRouter} from "@wormhole-sdk/interfaces/IExecutor.sol";
import {RequestLib} from "@wormhole-sdk/Executor/Request.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice Send, quote, and inbound verification for every Wormhole binding contract, over
///         Core `publishMessage` plus Executor delivery (the Standard Relayer is deprecated).
///
/// @dev Published payload: `abi.encodePacked(uint16 targetChain, bytes32 targetAddress, payload)`.
///      A VAA names its emitter but no destination, and anyone may submit it anywhere; receivers
///      share one CREATE2 address across parity chains and trust the same source transmitter,
///      so without this prefix a VAA addressed to one chain would execute on every other.
library WormholeMessage {
    bytes4 internal constant GAS_LIMIT_ATTRIBUTE = bytes4(keccak256("crossecute.wormhole.gasLimit"));

    /// @dev The Executor has no default; a gas instruction is required. Matches CCIP's own
    ///      default; not measured against this protocol's delivery paths.
    uint256 internal constant DEFAULT_GAS_LIMIT = 200_000;

    /// @dev `CONSISTENCY_LEVEL_FINALIZED` in the SDK's `constants/ConsistencyLevel.sol`.
    uint8 internal constant CONSISTENCY_FINALIZED = 1;

    /// @dev `RelayInstructionLib.RECV_INST_TYPE_GAS`: `(uint8 1, uint128 gasLimit, uint128 msgVal)`.
    uint8 internal constant RELAY_INSTRUCTION_GAS = 1;

    /// @dev VAA v1: version(1) guardianSetIndex(4) signatureCount(1) signatures(66 each), then
    ///      body: timestamp(4) nonce(4) emitterChain(2) emitterAddress(32) sequence(8)
    ///      consistencyLevel(1) payload.
    uint256 private constant VAA_SIGNATURES_OFFSET = 6;
    uint256 private constant VAA_SIGNATURE_SIZE = 66;
    uint256 private constant VAA_BODY_HEADER_SIZE = 51;
    uint256 private constant ENVELOPE_HEADER_SIZE = 34;

    /// @dev ERC-7201-style slot for the consumed-VAA set, shared by every contract using this
    ///      library so none of them adds a field to its own proxy layout.
    bytes32 private constant CONSUMED_SLOT =
        keccak256(abi.encode(uint256(keccak256("crossecute.wormhole.consumed")) - 1)) & ~bytes32(uint256(0xff));

    error UnknownWormholeAttribute(bytes attribute);
    error UnsupportedWormholeRecipient(bytes addr);
    error UnsupportedWormholeSender(bytes32 emitterAddress);
    error InsufficientWormholeValue(uint256 value, uint256 messageFee);
    error WormholeGatewayRevoked();
    error InvalidVaa(string reason);
    error MalformedVaa();
    error WrongDestination(uint16 targetChain, bytes32 targetAddress);
    error VaaAlreadyConsumed(bytes32 vaaHash);
    error UnexpectedValue();

    /* ================================== sending =================================== */

    struct Route {
        address coreBridge;
        address quoterRouter;
        address quoter;
        uint16 targetChain;
    }

    /// @dev `value` covers Core's message fee plus the Executor's price. The router refunds any
    ///      excess over its quote to `refundTo` (`OutboundBase._refundTo()`) and reverts
    ///      `Underpaid` below it. The returned id is the Core sequence.
    function send(
        Route memory route,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value,
        address refundTo
    ) internal returns (bytes32) {
        bytes32 target = recipientOf(recipient);
        uint256 messageFee = ICoreBridge(route.coreBridge).messageFee();
        if (value < messageFee) revert InsufficientWormholeValue(value, messageFee);
        uint64 sequence = ICoreBridge(route.coreBridge).publishMessage{value: messageFee}(
            0, abi.encodePacked(route.targetChain, target, payload), CONSISTENCY_FINALIZED
        );
        _requestExecution(route, target, refundTo, sequence, gasLimitFrom(attributes), value - messageFee);
        return bytes32(uint256(sequence));
    }

    /// @dev Split out of `send` for stack depth under the legacy (non-IR) pipeline.
    function _requestExecution(
        Route memory route,
        bytes32 target,
        address refundTo,
        uint64 sequence,
        uint128 gasLimit,
        uint256 executorValue
    ) private {
        IExecutorQuoterRouter(route.quoterRouter).requestExecution{value: executorValue}(
            route.targetChain,
            target,
            refundTo,
            route.quoter,
            _requestBytes(route.coreBridge, sequence),
            relayInstructions(gasLimit)
        );
    }

    /// @dev Prices the request for the next sequence this contract will publish, which is the
    ///      one `send` would use.
    function quote(Route memory route, bytes memory recipient, bytes[] memory attributes, address refundTo)
        internal
        view
        returns (uint256)
    {
        uint64 sequence = ICoreBridge(route.coreBridge).nextSequence(address(this));
        return ICoreBridge(route.coreBridge).messageFee()
            + IExecutorQuoterRouter(route.quoterRouter)
                .quoteExecution(
                route.targetChain,
                recipientOf(recipient),
                refundTo,
                route.quoter,
                _requestBytes(route.coreBridge, sequence),
                relayInstructions(gasLimitFrom(attributes))
            );
    }

    function _requestBytes(address coreBridge, uint64 sequence) private view returns (bytes memory) {
        return RequestLib.encodeVaaMultiSigRequest(
            ICoreBridge(coreBridge).chainId(), bytes32(uint256(uint160(address(this)))), sequence
        );
    }

    function relayInstructions(uint128 gasLimit) internal pure returns (bytes memory) {
        return abi.encodePacked(RELAY_INSTRUCTION_GAS, gasLimit, uint128(0));
    }

    /// @dev EVM recipients only: anything but 20 bytes would be silently truncated or padded.
    function recipientOf(bytes memory recipient) internal pure returns (bytes32) {
        bytes memory addr = Erc7930.parseStrict(recipient).addr;
        if (addr.length != 20) revert UnsupportedWormholeRecipient(addr);
        return bytes32(uint256(uint160(bytes20(addr))));
    }

    /// @notice One attribute: the destination gas limit, as
    ///         `abi.encodePacked(GAS_LIMIT_ATTRIBUTE, abi.encode(gasLimit))`, at most
    ///         `type(uint128).max`. Anything else is refused per ERC-7786.
    function gasLimitFrom(bytes[] memory attributes) internal pure returns (uint128) {
        if (attributes.length == 0) return uint128(DEFAULT_GAS_LIMIT);
        if (attributes.length > 1) revert UnknownWormholeAttribute(attributes[1]);
        bytes memory attribute = attributes[0];
        if (attribute.length != 36) revert UnknownWormholeAttribute(attribute);
        bytes4 selector;
        uint256 gasLimit;
        assembly {
            selector := mload(add(attribute, 32))
            gasLimit := mload(add(attribute, 36))
        }
        if (selector != GAS_LIMIT_ATTRIBUTE || gasLimit > type(uint128).max) {
            revert UnknownWormholeAttribute(attribute);
        }
        return uint128(gasLimit);
    }

    /* ================================= receiving ================================== */

    /// @notice Verify `vaa` for delivery to `address(this)`, mark it consumed, and return its
    ///         emitter and inner payload.
    ///
    /// @dev Permissionless by design (any relay provider, or anyone, may submit). Still gated
    ///      on `GATEWAY_ROLE` being held by `coreBridge`, so `ReceiverBase.revokeGateway`
    ///      disconnects Wormhole exactly as it would a push-style gateway.
    ///
    /// @dev Core returns the payload in memory, but `_onMessage`/`_onInbound` take calldata,
    ///      so the payload is sliced from `vaa` at its v1 offset and required to hash-equal
    ///      the one Core verified.
    ///
    /// @dev Replay is keyed on `vm.hash` (over the body, not the signatures), so a VAA
    ///      re-signed by a different guardian subset is still the same message.
    function verify(address coreBridge, bool gatewayHeld, bytes calldata vaa)
        internal
        returns (uint16 emitterChain, address emitter, bytes calldata inner)
    {
        if (msg.value != 0) revert UnexpectedValue();
        if (!gatewayHeld) revert WormholeGatewayRevoked();

        (CoreBridgeVM memory vm, bool valid, string memory reason) = ICoreBridge(coreBridge).parseAndVerifyVM(vaa);
        if (!valid) revert InvalidVaa(reason);

        bytes calldata payload = _payloadOf(vaa);
        if (keccak256(payload) != keccak256(vm.payload)) revert MalformedVaa();
        if (payload.length < ENVELOPE_HEADER_SIZE) revert MalformedVaa();

        uint16 targetChain = uint16(bytes2(payload[0:2]));
        bytes32 targetAddress = bytes32(payload[2:34]);
        if (
            targetChain != ICoreBridge(coreBridge).chainId()
                || targetAddress != bytes32(uint256(uint160(address(this))))
        ) revert WrongDestination(targetChain, targetAddress);

        _consume(vm.hash);
        return (vm.emitterChainId, senderOf(vm.emitterAddress), payload[ENVELOPE_HEADER_SIZE:]);
    }

    function _payloadOf(bytes calldata vaa) private pure returns (bytes calldata) {
        if (vaa.length < VAA_SIGNATURES_OFFSET) revert MalformedVaa();
        uint256 start = VAA_SIGNATURES_OFFSET + uint256(uint8(vaa[5])) * VAA_SIGNATURE_SIZE + VAA_BODY_HEADER_SIZE;
        if (vaa.length < start) revert MalformedVaa();
        return vaa[start:];
    }

    /// @dev Wormhole-format addresses are left-padded; nonzero high bytes are not an EVM
    ///      emitter and must not be truncated into one.
    function senderOf(bytes32 emitterAddress) internal pure returns (address) {
        if (uint256(emitterAddress) > type(uint160).max) revert UnsupportedWormholeSender(emitterAddress);
        return address(uint160(uint256(emitterAddress)));
    }

    function consumed(bytes32 vaaHash) internal view returns (bool) {
        return _consumedSet()[vaaHash];
    }

    function _consume(bytes32 vaaHash) private {
        mapping(bytes32 => bool) storage set = _consumedSet();
        if (set[vaaHash]) revert VaaAlreadyConsumed(vaaHash);
        set[vaaHash] = true;
    }

    function _consumedSet() private pure returns (mapping(bytes32 => bool) storage set) {
        bytes32 slot = CONSUMED_SLOT;
        assembly {
            set.slot := slot
        }
    }
}
