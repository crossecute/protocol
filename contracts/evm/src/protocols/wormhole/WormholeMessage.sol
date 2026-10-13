// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICoreBridge, CoreBridgeVM} from "@wormhole-sdk/interfaces/ICoreBridge.sol";
import {IExecutor} from "@wormhole-sdk/interfaces/IExecutor.sol";
import {RequestLib} from "@wormhole-sdk/Executor/Request.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice The relay-provider quoters a deferred execution may be paid under.
interface IWormholeQuoters {
    function isQuoter(address quoter) external view returns (bool);
}

/// @notice Send, quote, and inbound verification for every Wormhole binding contract, over
///         Core `publishMessage` plus Executor delivery with a relay provider's signed quote
///         (the Standard Relayer is deprecated).
///
/// @dev `send` and `quote` are `public`, so they are deployed once and linked rather than
///      inlined into every Wormhole contract (#29). A linked call is a `DELEGATECALL`, so it runs in the caller's
///      context and pays from the caller's balance as before. `verify` stays `internal`, since
///      it returns a calldata slice.
///
/// @dev Published payload: `abi.encodePacked(uint16 targetChain, bytes32 targetAddress, payload)`.
///      A VAA names its emitter but no destination, and anyone may submit it anywhere; receivers
///      and transceivers each share one address across parity chains and trust the same sender,
///      so without this prefix a VAA addressed to one chain would execute on every other.
library WormholeMessage {
    // forge-lint: disable-next-line(unsafe-typecast) a selector is the hash's first 4 bytes
    bytes4 internal constant EXECUTION_ATTRIBUTE = bytes4(keccak256("crossecute.wormhole.execution"));
    // forge-lint: disable-next-line(unsafe-typecast) a selector is the hash's first 4 bytes
    bytes4 internal constant DEFERRED_ATTRIBUTE = bytes4(keccak256("crossecute.wormhole.deferred"));

    /// @dev The Executor's signed quote, version 1: header (prefix, quoter, payee, source chain,
    ///      destination chain, expiry), then base fee, destination gas price, source and
    ///      destination USD prices, and a 65-byte signature.
    bytes4 internal constant EQ01 = "EQ01";
    uint256 internal constant EQ01_LENGTH = 165;
    /// @dev The signature covers the keccak256 of the bytes before it.
    uint256 private constant EQ01_SIGNED_LENGTH = 100;

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
    bytes32 private constant DEFERRED_SLOT =
        keccak256(abi.encode(uint256(keccak256("crossecute.wormhole.deferred")) - 1)) & ~bytes32(uint256(0xff));

    /// @custom:storage-location erc7201:crossecute.wormhole.deferred
    struct Deferred {
        mapping(uint64 sequence => Delivery) pending;
        /// @dev The sum of pending `maxPrice`s, held in this contract's balance.
        uint256 escrowed;
        /// @dev Read only by a transceiver; a transmitter defers to its transceiver's set.
        mapping(address quoter => bool) quoters;
    }

    event ExecutionDeferred(uint64 indexed sequence, Delivery delivery);
    event QuoterSet(address indexed quoter, bool approved);

    error InsufficientWormholeValue(uint256 value, uint256 required);
    error NoSignedQuote();
    error UnsupportedQuote();
    error QuoteForAnotherRoute(uint16 srcChain, uint16 dstChain);
    error QuoteExpired(uint64 expiry);
    error RefundFailed(address to, uint256 amount);
    error UnknownDeferral(uint64 sequence);
    error QuoteAboveBudget(uint256 price, uint256 maxPrice);
    error QuoteSignerMismatch(address signer, address quoter);
    error QuoterNotApproved(address quoter);
    error EscrowSpent(uint256 balance, uint256 escrowed);
    error WormholeGatewayRevoked();
    error InvalidVaa(string reason);
    error MalformedVaa();
    error WrongDestination(uint16 targetChain, bytes32 targetAddress);
    error VaaAlreadyConsumed(bytes32 vaaHash);
    error UnexpectedValue();

    /* ================================== sending =================================== */

    struct Route {
        address coreBridge;
        address executor;
        uint16 targetChain;
    }

    /// @dev A send's execution terms: the caller's quote, the gas it buys, and their price. When
    ///      deferred there is no quote yet and `price` is the most a later request may pay.
    struct Execution {
        bytes signedQuote;
        uint128 gasLimit;
        uint256 price;
        bool deferred;
    }

    /// @notice What an execution request names: the published message, where it goes, the gas
    ///         bought, and who is refunded. A deferral stores it whole (three slots), so a
    ///         request names only the sequence.
    struct Delivery {
        uint64 sequence;
        uint16 targetChain;
        address refundTo;
        bytes32 recipient;
        uint128 gasLimit;
        uint128 maxPrice;
    }

    /// @dev Publishes, then requests execution with the caller's signed quote, paying the price
    ///      `quote` computes from it and refunding the rest to `refundTo`: the Executor forwards
    ///      all it is sent to the quote's payee and refunds nothing. Deferred, it escrows
    ///      `maxPrice` instead, for `requestDeferred`. Returns zero, ERC-7786's "sent" (see
    ///      `ProviderSendSpec`); the Core sequence is in `LogMessagePublished`.
    function send(
        Route memory route,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value,
        address refundTo,
        uint256 defaultGas
    ) public returns (bytes32) {
        Execution memory e = execution(route, attributes, defaultGas);
        uint256 messageFee = ICoreBridge(route.coreBridge).messageFee();
        if (value < messageFee + e.price) revert InsufficientWormholeValue(value, messageFee + e.price);

        Delivery memory d = Delivery(0, route.targetChain, refundTo, recipientOf(recipient), e.gasLimit, 0);
        d.sequence = ICoreBridge(route.coreBridge).publishMessage{value: messageFee}(
            0, abi.encodePacked(d.targetChain, d.recipient, payload), CONSISTENCY_FINALIZED
        );
        if (e.deferred) _defer(d, e.price);
        else _requestExecution(route, d, e.signedQuote, e.price);
        _refund(refundTo, value - messageFee - e.price);
        _requireEscrowHeld();
        return bytes32(0);
    }

    /// @notice Request execution of a deferred message, paying from its escrow. Permissionless:
    ///         the stored deferral fixes everything but the quote, and the quote must be signed
    ///         by its own quoter, one `quoters` approves, and priced within `maxPrice`. The payee
    ///         is inside the signed bytes, so a caller cannot redirect the payment.
    /// @dev One request per deferral. If the provider does not deliver, `executeVAAv1` remains.
    function requestDeferred(
        address coreBridge,
        address executor,
        address quoters,
        uint64 sequence,
        bytes memory signedQuote
    ) public {
        Deferred storage s = _deferred();
        Delivery memory d = s.pending[sequence];
        if (d.refundTo == address(0)) revert UnknownDeferral(sequence);
        delete s.pending[sequence];
        s.escrowed -= d.maxPrice;

        Route memory route = Route(coreBridge, executor, d.targetChain);
        uint256 price = executionPrice(route, signedQuote, d.gasLimit);
        if (price > d.maxPrice) revert QuoteAboveBudget(price, d.maxPrice);
        _requireApprovedQuoter(quoters, signedQuote);

        _requestExecution(route, d, signedQuote, price);
        _refund(d.refundTo, d.maxPrice - price);
    }

    function setQuoter(address quoter, bool approved) internal {
        _deferred().quoters[quoter] = approved;
        emit QuoterSet(quoter, approved);
    }

    function isQuoter(address quoter) internal view returns (bool) {
        return _deferred().quoters[quoter];
    }

    function escrowed() internal view returns (uint256) {
        return _deferred().escrowed;
    }

    /// @dev `maxPrice` was bounded to `uint128` when parsed. A stored `refundTo` is never zero
    ///      (a caller or this contract), so it marks the entry as present.
    function _defer(Delivery memory d, uint256 maxPrice) private {
        // forge-lint: disable-next-line(unsafe-typecast) bounded in `execution`
        d.maxPrice = uint128(maxPrice);
        Deferred storage s = _deferred();
        s.pending[d.sequence] = d;
        s.escrowed += maxPrice;
        emit ExecutionDeferred(d.sequence, d);
    }

    /// @dev A send pays from this contract's balance, so it must not reach pending escrow.
    function _requireEscrowHeld() private view {
        uint256 held = _deferred().escrowed;
        if (address(this).balance < held) revert EscrowSpent(address(this).balance, held);
    }

    function _requireApprovedQuoter(address quoters, bytes memory signedQuote) private view {
        // forge-lint: disable-next-line(unsafe-typecast) the 20-byte quoter field
        address quoter = address(uint160(_word(signedQuote, 4, 20)));
        bytes32 digest;
        bytes32 r;
        bytes32 sig;
        assembly {
            digest := keccak256(add(signedQuote, 32), EQ01_SIGNED_LENGTH)
            r := mload(add(signedQuote, add(32, EQ01_SIGNED_LENGTH)))
            sig := mload(add(signedQuote, add(64, EQ01_SIGNED_LENGTH)))
        }
        // forge-lint: disable-next-line(unsafe-typecast) the 1-byte v field
        address signer = ECDSA.recover(digest, uint8(_word(signedQuote, 164, 1)), r, sig);
        if (signer != quoter) revert QuoteSignerMismatch(signer, quoter);
        if (!IWormholeQuoters(quoters).isQuoter(quoter)) revert QuoterNotApproved(quoter);
    }

    function _deferred() private pure returns (Deferred storage s) {
        bytes32 slot = DEFERRED_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @notice Core's message fee plus the execution price, or the escrow when deferred,
    ///         reverting wherever `send` would.
    function quote(Route memory route, bytes memory recipient, bytes[] memory attributes, uint256 defaultGas)
        public
        view
        returns (uint256)
    {
        recipientOf(recipient);
        return ICoreBridge(route.coreBridge).messageFee() + execution(route, attributes, defaultGas).price;
    }

    /// @notice The terms `send` pays and `quote` prices, from the one attribute.
    function execution(Route memory route, bytes[] memory attributes, uint256 defaultGas)
        internal
        view
        returns (Execution memory e)
    {
        // forge-lint: disable-next-line(unsafe-typecast) the selector, after the length check
        if (attributes.length != 0 && attributes[0].length >= 4 && bytes4(attributes[0]) == DEFERRED_ATTRIBUTE) {
            (, bytes memory body) = ProviderAttribute.body(attributes, DEFERRED_ATTRIBUTE, 64);
            (uint256 gas, uint256 maxPrice) = abi.decode(body, (uint256, uint256));
            e.gasLimit = _gasLimit(gas, defaultGas, attributes[0]);
            if (maxPrice > type(uint128).max) revert ProviderAttribute.UnsupportedAttribute(attributes[0]);
            e.price = maxPrice;
            e.deferred = true;
            return e;
        }
        (e.signedQuote, e.gasLimit) = executionFrom(attributes, defaultGas);
        e.price = executionPrice(route, e.signedQuote, e.gasLimit);
    }

    function _requestExecution(Route memory route, Delivery memory d, bytes memory signedQuote, uint256 price) private {
        IExecutor(route.executor).requestExecution{value: price}(
            d.targetChain,
            d.recipient,
            d.refundTo,
            signedQuote,
            _requestBytes(route.coreBridge, d.sequence),
            relayInstructions(d.gasLimit)
        );
    }

    /// @notice What a relay provider charges, in this chain's native currency, for `gasLimit` on
    ///         the destination under its EQ01 quote.
    /// @dev The Executor's own formula (`ExecutorQuoter.estimateQuote`): the base fee, in units of
    ///      10^-10 of the source currency, plus the destination gas at the quoted price converted
    ///      by the two USD prices. It assumes 18-decimal native currency and gas priced in wei on
    ///      both chains, true of every chain Wormhole reaches here; it reproduced the Executor
    ///      API's `estimatedCost` exactly (deploy/CHECKS.md §3). The Executor checks the chains and
    ///      expiry again but not the payment, which the provider enforces off-chain.
    /// @dev The quote's signature is not checked: a quote from a provider that will not relay
    ///      costs only the caller who chose it, and anyone may still relay the VAA.
    function executionPrice(Route memory route, bytes memory signedQuote, uint128 gasLimit)
        internal
        view
        returns (uint256)
    {
        // forge-lint: disable-next-line(unsafe-typecast) the leading 4 bytes, after the length check
        if (signedQuote.length != EQ01_LENGTH || bytes4(signedQuote) != EQ01) revert UnsupportedQuote();
        // Each field is read at its own width, so the narrowing casts below lose nothing.
        // forge-lint: disable-start(unsafe-typecast)
        uint16 srcChain = uint16(_word(signedQuote, 56, 2));
        uint16 dstChain = uint16(_word(signedQuote, 58, 2));
        if (srcChain != ICoreBridge(route.coreBridge).chainId() || dstChain != route.targetChain) {
            revert QuoteForAnotherRoute(srcChain, dstChain);
        }
        uint64 expiry = uint64(_word(signedQuote, 60, 8));
        // forge-lint: disable-end(unsafe-typecast)
        // forge-lint: disable-next-line(block-timestamp) the Executor's own expiry rule
        if (expiry <= block.timestamp) revert QuoteExpired(expiry);
        uint256 srcPrice = _word(signedQuote, 84, 8);
        if (srcPrice == 0) revert UnsupportedQuote();
        return _word(signedQuote, 68, 8) * 1e8 + uint256(gasLimit) * _word(signedQuote, 76, 8)
            * _word(signedQuote, 92, 8) / srcPrice;
    }

    /// @dev The big-endian integer `size` bytes long at `offset`, which the caller has bounded.
    function _word(bytes memory b, uint256 offset, uint256 size) private pure returns (uint256 v) {
        assembly {
            v := shr(sub(256, mul(size, 8)), mload(add(add(b, 32), offset)))
        }
    }

    function _refund(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert RefundFailed(to, amount);
    }

    function _requestBytes(address coreBridge, uint64 sequence) private view returns (bytes memory) {
        return RequestLib.encodeVaaMultiSigRequest(
            ICoreBridge(coreBridge).chainId(), bytes32(uint256(uint160(address(this)))), sequence
        );
    }

    function relayInstructions(uint128 gasLimit) internal pure returns (bytes memory) {
        return abi.encodePacked(RELAY_INSTRUCTION_GAS, gasLimit, uint128(0));
    }

    function recipientOf(bytes memory recipient) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(ProviderAddress.evmRecipient(recipient))));
    }

    /// @notice One of two attributes, which every send needs. Either a relay provider's signed
    ///         EQ01 quote for this pair of chains and the destination gas, as
    ///         `abi.encodePacked(EXECUTION_ATTRIBUTE, abi.encode(signedQuote, gasLimit))`, or a
    ///         deferral, `abi.encodePacked(DEFERRED_ATTRIBUTE, abi.encode(gasLimit, maxPrice))`,
    ///         for a sender that cannot hold a quote until it lands (a multisig). A `gasLimit` of
    ///         zero means `defaultGas`. Anything else is refused per ERC-7786.
    /// @dev Required: the Executor prices only from a quote fetched off-chain, and its on-chain
    ///      quoter router is not deployed on these chains (#53).
    function executionFrom(bytes[] memory attributes, uint256 defaultGas)
        internal
        pure
        returns (bytes memory signedQuote, uint128 gasLimit)
    {
        (bool present, bytes memory body) = ProviderAttribute.body(attributes, EXECUTION_ATTRIBUTE, 0);
        if (!present) revert NoSignedQuote();
        uint256 gas;
        (signedQuote, gas) = abi.decode(body, (bytes, uint256));
        gasLimit = _gasLimit(gas, defaultGas, attributes[0]);
    }

    function _gasLimit(uint256 gas, uint256 defaultGas, bytes memory attribute) private pure returns (uint128) {
        if (gas == 0) gas = defaultGas;
        if (gas > type(uint128).max) revert ProviderAttribute.UnsupportedAttribute(attribute);
        // forge-lint: disable-next-line(unsafe-typecast) bounded above
        return uint128(gas);
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
        return (vm.emitterChainId, ProviderAddress.evmSender(vm.emitterAddress), payload[ENVELOPE_HEADER_SIZE:]);
    }

    function _payloadOf(bytes calldata vaa) private pure returns (bytes calldata) {
        if (vaa.length < VAA_SIGNATURES_OFFSET) revert MalformedVaa();
        uint256 start = VAA_SIGNATURES_OFFSET + uint256(uint8(vaa[5])) * VAA_SIGNATURE_SIZE + VAA_BODY_HEADER_SIZE;
        if (vaa.length < start) revert MalformedVaa();
        return vaa[start:];
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
