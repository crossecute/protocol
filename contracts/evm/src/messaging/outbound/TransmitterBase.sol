// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {ICommitFinalize} from "src/messaging/inbound/ReceiverBase.sol";
import {Executor} from "src/messaging/Executor.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Call} from "src/messaging/Call.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {IERC7786GatewaySource} from
    "@openzeppelin/contracts/interfaces/draft-IERC7786.sol";

/// @title IAccountTransceiver
/// @notice Everything an account needs from the transceiver whose address it already stores.
///
/// @dev NAMED FOR THE RELATIONSHIP RATHER THAN FOR ONE OF ITS FUNCTIONS, because an account
///      holds exactly one transceiver address and one interface over it is the shape that
///      cannot drift as the things it needs from that address change.
interface IAccountTransceiver {
    function bootstrap(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external payable;

    function bootstrapElements(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        bytes[] calldata elements,
        bytes[] calldata attributes
    ) external payable;

    /// @dev The quotes live on the same interface as the sends they price, so a transmitter
    ///      cannot hold a reference that can bootstrap but not quote.
    function quoteBootstrap(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external view returns (uint256);

    function quoteBootstrapElements(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        bytes[] calldata elements,
        bytes[] calldata attributes
    ) external view returns (uint256);

    /// @notice The chain identifier a destination is configured under, opaque here.
    ///
    /// @dev THIS IS WHY AN ACCOUNT HOLDS NO ROUTE TABLE. Reading it through the transceiver
    ///      rather than storing a copy means a msig adding a destination is one configuration
    ///      change, not a migration across every account that might want to reach it. The
    ///      send path does not need it (an ERC-7786 recipient names its own chain); it is
    ///      here so a caller never has to keep its own table.
    function routeTo(bytes32 chainKey) external view returns (bytes memory);
}

/// @title TransmitterBase
/// @notice The per-user account on the home chain, and the source-side entry point. One
///         transmitter per protocol per user, routing to every destination.
///
/// @dev THE DESTINATION IS A PARAMETER, NOT STATE. A single transmitter fans out to every
///      chain, which is also what keeps one receiver per (transmitter, destination): the
///      salt on the far side is the account, and there is one account per user per protocol.
///
/// @dev OWNERSHIP IS DECLARED, NOT INHERITED, and the modifier is `onlyAccountOwner` rather
///      than `onlyOwner`. A provider SDK that brings `Ownable` also brings `onlyOwner`, and
///      two base classes declaring one name forces every derived contract to override it:
///      the same collision the seam exists to avoid, one level down. `TransceiverBase`
///      sidesteps it identically, with `onlyAdmin`. Concrete contracts answer `_owner` and
///      `_checkOwner` from whatever authority they already have; `LzTransmitter` uses
///      `OwnableUpgradeable`, which also exposes `renounceOwnership`, and renouncing bricks
///      the transmitter since every entry point here is owner-gated.
///
/// @dev IT HOLDS NO REGISTRY POINTER AND NO ROUTES. The chainKey derivation is pure, and the
///      hub does the directory lookup once, on the home chain. Keeping that dependency on
///      one contract on one chain is what lets this be a pure commit-and-forward contract.
///
/// @dev THE COMMITMENT IS HASHED FOR THE DESTINATION, NOT FOR HERE. Easy to get wrong and
///      impossible to notice until a live message fails: `Commitment.hashCalls(calls)` folds
///      in the LOCAL chainKey, which here is the home chain, and the receiver recomputes on
///      the DESTINATION chain. So the previews below hash with the destination's key, and
///      the chain-binding still does its job.
abstract contract TransmitterBase is
    OutboundBase,
    Executor,
    Initializable,
    IERC7786GatewaySource
{
    /// The local transceiver for this protocol, which carries every message out.
    address public transceiver;
    /// The caller-chosen half of this account's CREATE2 salt.
    ///
    /// @dev STORED BECAUSE `bootstrap` HAS TO STATE IT. The destination derives this
    ///      account's address from `(owner, salt)`, and an address cannot be reversed into
    ///      its own salt, so the value has to travel and this is the only place that knows it
    ///      without a lookup.
    bytes32 public accountSalt;

    /// Destinations this account has already been stood up on.
    ///
    /// @dev IT RECORDS THAT A BOOTSTRAP WAS DISPATCHED, NOT THAT ONE LANDED, and nothing on
    ///      this chain can close that gap: the message is asynchronous, and on a parity chain
    ///      no report ever comes back, because the hub derives the receiver's address rather
    ///      than being told it (see `SpokeTransceiverBase.addressesDiverge`). A flag that
    ///      waited for confirmation would never be set on most chains.
    ///
    ///      That is sound because delivery is retryable at the provider: a bootstrap that
    ///      reverts on arrival can be re-executed by anyone, so it is pending rather than
    ///      lost. See [Failure handling](../../../../docs/message-flow.md#failure-handling).
    ///
    /// @dev THE ONE CASE IT CANNOT SURVIVE is a permanently undeliverable bootstrap: a route
    ///      configured to the wrong chain, or a destination that will never accept it. This
    ///      flag then blocks the retry. Both causes are transceiver misconfiguration, which
    ///      is write-once and a redeploy to correct, so the account was stranded either way.
    mapping(bytes32 destinationChainKey => bool) private _bootstrapped;

    event TransmitterConfigured(address indexed owner, address indexed transceiver);
    event DestinationBootstrapped(bytes32 indexed destinationChainKey);
    /// @dev Distinct from a bridged delivery: an execution the owner drove directly must be
    ///      distinguishable on-chain from one a commitment discharged.
    event Executed(address indexed caller, uint256 callCount);

    error NoTransceiver();
    /// @dev An account's peer is itself on every chain, so any other recipient is either a
    ///      typo or an attempt to route this account's payload somewhere it has no receiver.
    error RecipientIsNotThisAccount(bytes recipient);
    /// @dev The peer address on an un-bootstrapped chain holds no code, so the payload fails
    ///      on delivery after the fee is spent. Refusing here makes that a local revert.
    error NotBootstrapped(bytes32 destinationChainKey);
    /// @dev A second bootstrap cannot deliver its payload anyway, because `CrossProxy` arms
    ///      exactly once and the receiver's `initialize` is single-shot, so it would burn a
    ///      fee to revert on arrival.
    error AlreadyBootstrapped(bytes32 destinationChainKey);
    /// @dev `Call[]` is what an EVM receiver executes and nothing else decodes it.
    error TypedPayloadToNonEvmDestination();
    /// @dev The mirror: an EVM receiver decodes `Call[]` and only `Call[]`, so opaque
    ///      elements would arrive undeliverable.
    error OpaquePayloadToEvmDestination();

    /// @notice Whether this account has been stood up on `destinationChainKey`.
    /// @dev Exposed so a caller can check before spending anything, and so an interface can
    ///      show which destinations are reachable without simulating a send.
    function isBootstrapped(bytes32 destinationChainKey) public view returns (bool) {
        return _bootstrapped[destinationChainKey];
    }

    /// @notice Whether this account has been stood up on an EVM chain, by plain chain id.
    function isBootstrappedOn(uint256 destinationChainId) external view returns (bool) {
        return _bootstrapped[ChainKey.forEvm(destinationChainId)];
    }

    function _requireBootstrapped(bytes32 chainKey) private view {
        if (!_bootstrapped[chainKey]) revert NotBootstrapped(chainKey);
    }

    function _requireNotBootstrapped(bytes32 chainKey) private view {
        if (_bootstrapped[chainKey]) revert AlreadyBootstrapped(chainKey);
    }

    /// @notice The account's owner. Declared, not implemented: see the contract note.
    function _owner() internal view virtual returns (address);

    /// @notice Reverts unless the caller is the owner. Declared, not implemented.
    function _checkOwner() internal view virtual;

    modifier onlyAccountOwner() {
        _checkOwner();
        _;
    }

    /* ================================== send =================================== */

    /// @notice Put a payload on the wire for this account's receiver on another chain.
    ///
    /// @dev THE ERC-7786 SOURCE ENTRY POINT, AND THE ONLY SEND. One signature covers every
    ///      destination, because a recipient is a binary interoperable address carrying its
    ///      own chain: the chain id, the ERC-7930 envelope, and the choice between typed and
    ///      opaque payloads are all folded into two arguments.
    ///
    /// @dev THE PAYLOAD ARRIVES BUILT, AND THAT COSTS ONE CHECK. A `bytes` payload cannot be
    ///      asked whether it holds `Call[]` or opaque elements, so this contract cannot
    ///      refuse a typed payload bound for a non-EVM chain or an opaque one bound for an
    ///      EVM chain. The pairing is the caller's to get right, and `payloadForCalls` /
    ///      `payloadForElements` exist so it is at least spelled here the way it is decoded
    ///      there. Path B still holds the envelope and does enforce it: see `_typedKey`.
    ///
    /// @dev THE RECIPIENT IS CHECKED, NOT TRUSTED. An account's peer is itself on every
    ///      chain, which is what lets it be its own endpoint, and it is derived precisely so
    ///      it cannot be wrong. Taking it as an argument reopens that, and a payload
    ///      addressed elsewhere would arrive at a contract that is not this account's
    ///      receiver, would not accept a `commit` from it, and would not match a commitment
    ///      bound to it.
    ///
    /// @return sendId Zero when the gateway has taken the message. A binding that returns
    ///         non-zero has a second step to perform and says so in its own NatSpec.
    function sendMessage(
        bytes calldata recipient,
        bytes calldata payload,
        bytes[] calldata attributes
    ) external payable onlyAccountOwner returns (bytes32 sendId) {
        bytes32 chainKey = _requireOwnRecipient(recipient);
        _requireBootstrapped(chainKey);
        if (payload.length == 0) revert EmptyPayload();

        emit MessageSent(
            bytes32(0),
            Erc7930.encodeEvm(block.chainid, address(this)),
            recipient,
            payload,
            msg.value,
            attributes
        );
        return _sendMessage(recipient, payload, attributes);
    }

    /// @notice Whether this account understands a per-send attribute.
    /// @dev REQUIRED BY ERC-7786 AND ANSWERED BY THE BINDING. Attributes are the provider's
    ///      vocabulary, decoded where the provider is known. Understanding none is the honest
    ///      answer for a base with no gateway behind it.
    function supportsAttribute(bytes4) external view virtual returns (bool) {
        return false;
    }

    /// @notice The interoperable address of this account on `destinationChainId`.
    /// @dev The value `sendMessage` expects, so a caller never has to assemble one.
    function recipientOn(uint256 destinationChainId) public view returns (bytes memory) {
        return Erc7930.encodeEvm(destinationChainId, address(this));
    }

    /// @notice The wire bytes for an EVM destination, which decodes `Call[]`.
    function payloadForCalls(Call[] calldata calls) public pure returns (bytes memory) {
        return Payload.encodeCalls(calls);
    }

    /// @notice The wire bytes for a destination whose calls this chain cannot express.
    function payloadForElements(bytes[] calldata elements)
        public
        pure
        returns (bytes memory)
    {
        return Payload.encodeElements(elements);
    }

    /// @notice The recipient must name this account, and the chain must be one this account
    ///         has been stood up on. Returns the chainKey so nothing parses twice.
    ///
    /// @dev THE ADDRESS CHECK BINDS ONLY WHERE THE ADDRESS IS DERIVABLE, WHICH IS EVM PARITY.
    ///      There `address(this)` is the answer and anything else is worth refusing locally.
    ///      It is NOT the answer on zkSync or Tron, whose CREATE2 formulas differ, nor on any
    ///      non-EVM chain, where the account is not a 20-byte address at all. So the check is
    ///      applied where it holds and skipped where it cannot, rather than weakened into
    ///      something that holds everywhere and means nothing. This is
    ///      `SpokeTransceiverBase.addressesDiverge` seen from the sending end; on those
    ///      chains the recipient is the caller's to get right, and the address the hub
    ///      recorded is in the registry under `receiverSlot(chainKey, owner, salt)`.
    function _requireOwnRecipient(bytes calldata recipient)
        private
        view
        returns (bytes32 chainKey)
    {
        if (recipient.length == 0) revert NoDestination();

        Erc7930.Interop memory io = Erc7930.parseStrict(recipient);
        if (io.chainType == Erc7930.CT_EIP155) {
            if (io.addr.length != 20 || address(bytes20(io.addr)) != address(this)) {
                revert RecipientIsNotThisAccount(recipient);
            }
        }
        return ChainKey.fromIdentifier(recipient);
    }

    /* ================================= bootstrap =============================== */

    /// @notice Stand this account up on a chain that has none, and run a payload there.
    ///
    /// @dev PATH B, AND THE ONLY ONE THE TRANSCEIVER IS IN. There is no peer to send to yet,
    ///      so the message goes to the one contract that already exists on that chain.
    ///      Afterwards every message takes path A, which is why the provenance bar gates the
    ///      FIRST message to a chain rather than every send.
    ///
    /// @dev IT PASSES THE OWNER AND SALT, NOT ITSELF. The destination derives this account's
    ///      address from that pair; its own address could not serve, because a CREATE2
    ///      address cannot be derived from itself. The transceiver checks the pair resolves
    ///      back to `msg.sender` before it sends anything.
    ///
    /// @dev THE PAIRING CHECK LIVES HERE, unlike on path A, because these overloads still
    ///      hold typed calls and the ERC-7930 envelope: `_evmKey` is `eip155` by
    ///      construction, `_typedKey` refuses a non-EVM destination, and `_opaqueKey` refuses
    ///      an EVM one. This is the last point that holds the envelope; downstream everything
    ///      speaks chainKeys, which are hashes and cannot be asked what they came from.
    function bootstrap(uint256 destinationChainId, Call[] calldata calls)
        external
        payable
        onlyAccountOwner
    {
        _bootstrapCalls(_evmKey(destinationChainId), calls, new bytes[](0));
    }

    function bootstrap(
        uint256 destinationChainId,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external payable onlyAccountOwner {
        _bootstrapCalls(_evmKey(destinationChainId), calls, attributes);
    }

    /// @notice `bootstrap`, for a destination named by its ERC-7930 identifier.
    function bootstrapTo(bytes calldata destinationChainIdentifier, Call[] calldata calls)
        external
        payable
        onlyAccountOwner
    {
        _bootstrapCalls(_typedKey(destinationChainIdentifier), calls, new bytes[](0));
    }

    function bootstrapTo(
        bytes calldata destinationChainIdentifier,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external payable onlyAccountOwner {
        _bootstrapCalls(_typedKey(destinationChainIdentifier), calls, attributes);
    }

    /// @notice `bootstrap`, in the portable form: for standing this account up on Solana,
    ///         Sui, Starknet, or anything else with no `Call`.
    function bootstrapTo(
        bytes calldata destinationChainIdentifier,
        bytes[] calldata elements
    ) external payable onlyAccountOwner {
        _bootstrapElements(_opaqueKey(destinationChainIdentifier), elements, new bytes[](0));
    }

    function bootstrapTo(
        bytes calldata destinationChainIdentifier,
        bytes[] calldata elements,
        bytes[] calldata attributes
    ) external payable onlyAccountOwner {
        _bootstrapElements(_opaqueKey(destinationChainIdentifier), elements, attributes);
    }

    /* ================================== quote ================================== */

    /// @notice What `sendMessage` would cost, in this chain's native currency.
    ///
    /// @dev ITS ARGUMENTS ARE `sendMessage`'s, MINUS THE VALUE. A caller builds the recipient
    ///      and payload once, prices them, and sends the same three arguments with the answer
    ///      attached; anything that changes the price is an argument to both, which is what
    ///      stops the two drifting. ERC-7786 defines no quote, so this is the protocol's own,
    ///      and a gateway that cannot answer leaves `_quoteMessage` reverting
    ///      `QuoteNotImplemented` with the off-chain measurement documented in its place.
    ///
    /// @dev IT CARRIES THE SAME GATES THE SEND DOES, because a quote that succeeded for a
    ///      message the send would refuse reports the operation ready when it is not. It is
    ///      UNGATED, unlike the send: it spends nothing, writes nothing, reveals nothing an
    ///      observer could not compute, and a signer reviewing a payload before the owner
    ///      submits it has to be able to call it.
    function quoteMessage(
        bytes calldata recipient,
        bytes calldata payload,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        bytes32 chainKey = _requireOwnRecipient(recipient);
        _requireBootstrapped(chainKey);
        if (payload.length == 0) revert EmptyPayload();

        return _quoteMessage(recipient, payload, attributes);
    }

    /// @notice What standing this account up on a chain that has none would cost.
    ///
    /// @dev IT ASKS THE TRANSCEIVER, BECAUSE THE TRANSCEIVER IS WHAT SENDS. Path B leaves
    ///      from there with a different envelope and a different counterpart, so pricing it
    ///      against this contract's `_quoteMessage` would answer for a message nobody sends.
    ///
    /// @dev THE PAIR IS NOT CHECKED, HERE OR THERE. `bootstrap` proves `(owner, salt)`
    ///      resolves to `msg.sender` before it spends anything; a quote spends nothing, and
    ///      is taken before the account it prices exists.
    function quoteBootstrap(
        uint256 destinationChainId,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        return _quoteBootstrapCalls(_evmKey(destinationChainId), calls, attributes);
    }

    /// @notice `quoteBootstrap`, for a destination named by its ERC-7930 identifier.
    function quoteBootstrapTo(
        bytes calldata destinationChainIdentifier,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        return _quoteBootstrapCalls(
            _typedKey(destinationChainIdentifier), calls, attributes
        );
    }

    /// @notice `quoteBootstrap`, in the portable form.
    function quoteBootstrapTo(
        bytes calldata destinationChainIdentifier,
        bytes[] calldata elements,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        if (transceiver == address(0)) revert NoTransceiver();
        bytes32 chainKey = _opaqueKey(destinationChainIdentifier);
        _requireNotBootstrapped(chainKey);

        return IAccountTransceiver(transceiver).quoteBootstrapElements(
            chainKey, _owner(), accountSalt, elements, attributes
        );
    }

    function _quoteBootstrapCalls(
        bytes32 chainKey,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) private view returns (uint256) {
        if (transceiver == address(0)) revert NoTransceiver();
        _requireNotBootstrapped(chainKey);

        return IAccountTransceiver(transceiver).quoteBootstrap(
            chainKey, _owner(), accountSalt, calls, attributes
        );
    }

    /* ============================== destination keys =========================== */

    /// @dev A `uint256` chain id is an `eip155` reference by construction, so there is no
    ///      chain type to check.
    function _evmKey(uint256 chainId) private pure returns (bytes32) {
        if (chainId == 0) revert NoDestination();
        return ChainKey.forEvm(chainId);
    }

    /// @dev The typed form only reaches a chain that executes `Call[]`.
    function _typedKey(bytes calldata identifier) private pure returns (bytes32) {
        if (identifier.length == 0) revert NoDestination();
        if (!Payload.isTypedDestination(identifier)) {
            revert TypedPayloadToNonEvmDestination();
        }
        return ChainKey.fromIdentifier(identifier);
    }

    /// @dev And the portable form only reaches one that does not.
    function _opaqueKey(bytes calldata identifier) private pure returns (bytes32) {
        if (identifier.length == 0) revert NoDestination();
        if (Payload.isTypedDestination(identifier)) {
            revert OpaquePayloadToEvmDestination();
        }
        return ChainKey.fromIdentifier(identifier);
    }

    /* ================================= plumbing ================================ */

    /// @dev THE FLAG IS SET BEFORE THE TRANSCEIVER IS CALLED. That call reaches a provider
    ///      endpoint and, through it, arbitrary code, so recording first means a re-entrant
    ///      second bootstrap for the same destination meets the flag it would otherwise race.
    ///      If the dispatch reverts the whole transaction unwinds and the flag goes with it,
    ///      so the ordering costs nothing.
    function _bootstrapCalls(
        bytes32 chainKey,
        Call[] calldata calls,
        bytes[] memory attributes
    ) private {
        if (transceiver == address(0)) revert NoTransceiver();
        _requireNotBootstrapped(chainKey);
        _markBootstrapped(chainKey);

        IAccountTransceiver(transceiver).bootstrap{value: msg.value}(
            chainKey, _owner(), accountSalt, calls, attributes
        );
    }

    function _bootstrapElements(
        bytes32 chainKey,
        bytes[] calldata elements,
        bytes[] memory attributes
    ) private {
        if (transceiver == address(0)) revert NoTransceiver();
        _requireNotBootstrapped(chainKey);
        _markBootstrapped(chainKey);

        IAccountTransceiver(transceiver).bootstrapElements{value: msg.value}(
            chainKey, _owner(), accountSalt, elements, attributes
        );
    }

    function _markBootstrapped(bytes32 chainKey) private {
        _bootstrapped[chainKey] = true;
        emit DestinationBootstrapped(chainKey);
    }

    /* ================================= execute ================================= */

    /// @notice Run a payload on THIS chain, with no bridge and no commitment.
    ///
    /// @dev IT TAKES NO DESTINATION, BECAUSE IT CANNOT HAVE ONE, and takes `Call[]` only: the
    ///      calls run here, in this transaction, on an EVM chain by construction.
    ///
    /// @dev IT RUNS THEM ITSELF RATHER THAN THROUGH A LOCAL RECEIVER. There is none to run
    ///      them in: a transmitter and its receivers share one address, and an address holds
    ///      one contract, so at home that address is the transmitter. A hub has no
    ///      receiver-manufacturing surface at all, which makes that structural rather than a
    ///      convention.
    ///      The two ends therefore share `Executor`: one loop, one policy check, one
    ///      all-or-nothing rule, whether the payload was authorized by the owner here or by a
    ///      commitment there.
    ///
    /// @dev PAYABLE, AND THE VALUE PASSES STRAIGHT THROUGH to the calls, which spend it per
    ///      the `value` in each element. Anything unspent stays here, at an address the owner
    ///      controls, so it is recoverable by a later payload rather than lost.
    function execute(Call[] calldata calls) external payable onlyAccountOwner {
        if (calls.length == 0) revert EmptyExecution();
        emit Executed(msg.sender, calls.length);
        _execute(calls);
    }

    /* ============================== payload helpers ============================ */

    /// @notice The call that pins `commitment` on a receiver, for inclusion in a payload
    ///         bound for that receiver's chain.
    ///
    /// @dev COMMITTING IS A CALL, NOT A MESSAGE KIND. To approve a payload now and run it
    ///      later, send one whose single element is this. It arrives, executes, and stores
    ///      the hash; anyone supplies the matching array to `finalize` afterwards. Nothing on
    ///      the wire distinguishes it from any other payload, which is why there is no
    ///      message-type tag anywhere in the protocol.
    ///
    /// @dev `pure`, so the payload a signer reviews is the payload that executes. The
    ///      receiver accepts a self-call because the only way to produce
    ///      `msg.sender == address(this)` there is through `_execute`, reachable only from an
    ///      authenticated inbound message or a gated entry point.
    function commitmentCall(address receiver, bytes32 commitment)
        public
        pure
        returns (Call memory)
    {
        return Call({
            target: receiver,
            value: 0,
            data: abi.encodeCall(ICommitFinalize.commit, (commitment))
        });
    }

    /// @notice The call that withdraws approval `index` on a receiver, for inclusion in a
    ///         payload bound for that receiver's chain.
    ///
    /// @dev CANCELLATION IS INHERENTLY REMOTE, because approvals are: a transmitter executes
    ///      directly and holds no queue, so there is nothing local to withdraw.
    ///
    /// @dev THE `expected` HASH EARNS ITS KEEP HERE. This element is built when the payload
    ///      is approved and executes whenever it lands, so the queue can have moved in
    ///      between and nobody is watching when it runs. Naming the approval as well as the
    ///      slot makes a stale index revert instead of withdrawing whatever sits there now.
    function cancellationCall(address receiver, uint256 index, bytes32 expected)
        public
        pure
        returns (Call memory)
    {
        return Call({
            target: receiver,
            value: 0,
            data: abi.encodeCall(ICommitFinalize.cancel, (index, expected))
        });
    }

    /* ================================= preview ================================= */

    /// @notice The commitment a payload will need on one EVM destination.
    ///
    /// @dev EVM DESTINATIONS AND NOTHING ELSE, AND WHAT STAYS HERE STAYS BECAUSE IT CANNOT GO
    ///      STALE. Every chain that executes `Call[]` hashes with keccak256, and
    ///      `ReceiverBase` enforces that exact fold from bytecode frozen alongside this, so
    ///      the answer is fixed for the life of the account and reading it here is strictly
    ///      better than a registry lookup: it holds without trusting whoever administers a
    ///      plugin table.
    ///
    ///      A scheme-parameterized preview belongs here for the mirror-image reason: it
    ///      would be frozen with the account, so it could only ever answer for primitives
    ///      that existed when the account was created. Non-EVM destinations are previewed
    ///      through `ChainRegistry.commitmentFor` instead, where the primitive is a
    ///      per-chainKey plugin and the set can grow. See `registry/ICommitmentScheme.sol`.
    ///
    /// @dev `pure`, so it runs off-chain against the exact array the signers reviewed. It is
    ///      what `commitmentCall` feeds, so a deferred payload's hash is checkable before
    ///      anything is approved.
    function commitmentFor(uint256 destinationChainId, Call[] memory calls)
        public
        pure
        returns (bytes32)
    {
        return Commitment.hashCalls(ChainKey.forEvm(destinationChainId), calls);
    }

    /// @notice `commitmentFor`, for an EVM destination named by its ERC-7930 identifier.
    /// @dev It refuses a non-EVM identifier rather than deferring to the registry: a preview
    ///      you can compute for a message you cannot send in this shape is a trap. The revert
    ///      names the mistake; `ChainRegistry.commitmentFor` is where that destination is
    ///      answered.
    function commitmentForChain(
        bytes calldata destinationChainIdentifier,
        Call[] memory calls
    ) public pure returns (bytes32) {
        if (!Payload.isTypedDestination(destinationChainIdentifier)) {
            revert TypedPayloadToNonEvmDestination();
        }
        return Commitment.hashCalls(
            ChainKey.fromIdentifier(destinationChainIdentifier), calls
        );
    }

    /// @notice Accept ETH, so a refunded fee has somewhere to land.
    ///
    /// @dev LOAD-BEARING ON THE BOOTSTRAP PATH. `bootstrap` proves the caller IS this
    ///      account, so a path B refund comes back HERE, and a provider's refund is a plain
    ///      value transfer: without this it reverts and takes the bootstrap with it, which is
    ///      the one message that cannot simply be retried cheaply. Nothing is stranded, since
    ///      `execute` is payable and this address is the owner's.
    receive() external payable {}

    function __TransmitterBase_init(address owner_, address transceiver_, bytes32 salt_)
        internal
        onlyInitializing
    {
        if (transceiver_ == address(0)) revert NoTransceiver();
        transceiver = transceiver_;
        accountSalt = salt_;
        emit TransmitterConfigured(owner_, transceiver_);
    }
}
