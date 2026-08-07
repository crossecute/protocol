// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {ICommitFinalize} from "src/messaging/inbound/ReceiverBase.sol";
import {Executor} from "src/messaging/Executor.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Commitment, Scheme} from "src/messaging/Commitment.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Call} from "src/messaging/Call.sol";

/// @title TransmitterBase
/// @notice The source-side entry point. One transmitter per protocol per user, routing
///         to every destination.
///
/// @dev THE DESTINATION IS A PARAMETER, NOT STATE. A single transmitter fans out to every
///      chain, so `submit` takes the destination per call. That also keeps one receiver
///      address per (transmitter, destination): the salt on the far side is the
///      transmitter, and there is exactly one transmitter per user per protocol.
///
/// @dev THE CALLER STILL NAMES A PLAIN CHAIN ID. `submit(8453, calls)` is the whole
///      interface for an EVM destination — no chainKey to look up, no eid to know, no
///      per-provider table to keep. The transmitter derives the chainKey purely (see
///      `ChainKey`) and the transceiver turns that into whatever its provider addresses
///      by. `submitTo` is the escape hatch for destinations that have no `uint256` chain
///      id at all.
///
/// @dev OWNERSHIP IS `OwnableUpgradeable`, NOT A HAND-ROLLED FIELD. A transmitter is
///      per-user and its owner is the party that asked the factory for it, so the standard
///      two-step-free `Ownable` semantics are what a user expects — including
///      `transferOwnership`, which a hand-rolled immutable `owner` could not offer.
///      Note this also exposes `renounceOwnership`: renouncing bricks the transmitter,
///      since `submit` is the only way to use one and it is owner-gated.
///
///      This is the opposite choice from `TransceiverBase`, deliberately. A transceiver
///      must compose with a message provider's SDK, which usually brings its own
///      `Ownable`, so it declares `_checkAdmin` and inherits no ownership at all. A
///      transmitter composes with nothing — it is a leaf contract cloned by the factory —
///      so there is no second authority for `Ownable` to collide with.
///
/// @dev IT HOLDS NO REGISTRY POINTER, DELIBERATELY. The chainKey derivation is pure, so
///      nothing here needs to read the directory; the hub transceiver does that lookup
///      once, on Ethereum. Keeping the dependency in one contract on one chain is what
///      lets the same transmitter code be a pure commit-and-forward contract.
///
/// @dev THE COMMITMENT IS HASHED FOR THE DESTINATION, NOT FOR HERE. This is the one thing
///      that is easy to get wrong and impossible to notice until a live message fails.
///      `Commitment.hashCalls(calls)` folds in the LOCAL chainKey, and on this contract that
///      is Ethereum. The receiver recomputes the same hash on the DESTINATION chain, so a
///      commitment built with the local key can never match. `_submit` therefore hashes
///      with the destination's key, and the chain-binding still does its job: the payload
///      is pinned to exactly one destination and cannot be replayed onto a sibling
///      deployment at the same address.
interface ITransceiverBootstrap {
    function bootstrap(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        Call[] calldata calls,
        bytes calldata providerData
    ) external payable;

    function bootstrapElements(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        bytes[] calldata elements,
        bytes calldata providerData
    ) external payable;
}

abstract contract TransmitterBase is OutboundBase, Executor, Initializable {
    /// The local transceiver for this protocol, which carries every message out.
    address public transceiver;
    /// The caller-chosen half of this account's CREATE2 salt.
    ///
    /// @dev STORED BECAUSE `bootstrap` HAS TO STATE IT. The destination derives this
    ///      account's address from `(owner, salt)`, and an address cannot be reversed into
    ///      its own salt — so the value has to travel, and this contract is the only place
    ///      that knows it without a lookup.
    bytes32 public accountSalt;

    event TransmitterConfigured(address indexed owner, address indexed transceiver);

    error NoTransceiver();

    /// @notice The account's owner. Declared, not implemented — see the note above.
    function _owner() internal view virtual returns (address);

    /// @notice Reverts unless the caller is the owner.
    function _checkOwner() internal view virtual;

    /// @dev NAMED `onlyAccountOwner`, NOT `onlyAccountOwner`, and that is not cosmetic. A
    ///      provider SDK that brings `Ownable` also brings an `onlyAccountOwner` modifier, and
    ///      two base classes declaring one name forces every derived contract to override
    ///      it — the same collision the seam exists to avoid, reappearing one level down.
    ///      `TransceiverBase` sidesteps it the same way, with `onlyAdmin`.
    modifier onlyAccountOwner() {
        _checkOwner();
        _;
    }
    /// @dev `Call[]` is what an EVM receiver executes; nothing else decodes it. Sending it
    ///      to a chain that cannot is a mistake worth catching here rather than on arrival.
    error TypedPayloadToNonEvmDestination();
    /// @dev The mirror. An EVM receiver decodes `Call[]` and only `Call[]` — opaque
    ///      elements would arrive undeliverable, so the portable form is refused for a
    ///      destination that has a typed one.
    error OpaquePayloadToEvmDestination();

    /// @dev Distinct from a bridged delivery, because an execution the owner drove
    ///      directly must be distinguishable on-chain from one a commitment discharged.
    event Executed(address indexed caller, uint256 callCount);

    /* ================================== send =================================== */

    /// @notice Send a payload to this account's receiver on one EVM destination.
    ///
    /// @dev PATH A, AND THE TRANSCEIVER IS NOT IN IT. This account is its own
    ///      message-provider endpoint and its peer on the far side is its own address, so
    ///      the payload goes straight there. The peer relationship is exactly 1:1 — one
    ///      account, one chain pair — which is the shape every provider's peer table
    ///      already has, and the reason an account can be an endpoint at all.
    ///
    /// @dev THE CALLER NAMES A PLAIN CHAIN ID. `send(8453, calls)` is the whole interface:
    ///      no chainKey to look up, no eid to know, no per-provider table to keep. A signer
    ///      reviewing the payload sees the chain id they expect rather than a hash they
    ///      would have to verify out of band.
    ///
    /// @dev THE TWO-ARGUMENT FORM TAKES THE ADAPTER'S DEFAULTS. Pass `providerData` when a
    ///      payload needs more destination gas than the default buys, or when the fee
    ///      should refund somewhere other than the owner. Empty is not a silent fallback:
    ///      it is the adapter deciding, and the adapter is the only thing that knows what
    ///      its provider expects.
    function send(uint256 destinationChainId, Call[] calldata calls)
        external
        payable
        onlyAccountOwner
    {
        _sendCalls(_evmKey(destinationChainId), calls, "");
    }

    /// @notice `send`, with provider-specific options for this one message.
    function send(
        uint256 destinationChainId,
        Call[] calldata calls,
        bytes calldata providerData
    ) external payable onlyAccountOwner {
        _sendCalls(_evmKey(destinationChainId), calls, providerData);
    }

    /// @notice `send`, for a destination named by its ERC-7930 identifier.
    /// @dev The typed form is refused for a non-EVM destination: `Call[]` is what an EVM
    ///      receiver executes, and nothing else decodes it. Use the opaque overload there.
    function sendTo(bytes calldata destinationChainIdentifier, Call[] calldata calls)
        external
        payable
        onlyAccountOwner
    {
        _sendCalls(_typedKey(destinationChainIdentifier), calls, "");
    }

    function sendTo(
        bytes calldata destinationChainIdentifier,
        Call[] calldata calls,
        bytes calldata providerData
    ) external payable onlyAccountOwner {
        _sendCalls(_typedKey(destinationChainIdentifier), calls, providerData);
    }

    /// @notice `send`, in the portable form — the escape hatch for Solana, Sui, Starknet,
    ///         and anything else with no `uint256` chain id and no `Call`.
    /// @dev The elements are that VM's own call encoding. Nothing here inspects one.
    function sendTo(bytes calldata destinationChainIdentifier, bytes[] calldata elements)
        external
        payable
        onlyAccountOwner
    {
        _sendElements(_opaqueKey(destinationChainIdentifier), elements, "");
    }

    function sendTo(
        bytes calldata destinationChainIdentifier,
        bytes[] calldata elements,
        bytes calldata providerData
    ) external payable onlyAccountOwner {
        _sendElements(_opaqueKey(destinationChainIdentifier), elements, providerData);
    }

    /* ================================= bootstrap =============================== */

    /// @notice Stand this account up on a chain that has none, and run a payload there.
    ///
    /// @dev PATH B, AND THE ONLY ONE THE TRANSCEIVER IS IN. There is no peer to send to
    ///      yet, so the message goes to the one contract that already exists on that
    ///      chain. Afterwards every message takes path A and this contract is not involved
    ///      again — which is why the provenance bar gates the FIRST message to a chain
    ///      rather than every send.
    ///
    /// @dev IT PASSES THE OWNER AND SALT, NOT ITSELF. The destination derives this
    ///      account's address from that pair; its own address could not serve, because a
    ///      CREATE2 address cannot be derived from itself. The transceiver checks the pair
    ///      resolves back to `msg.sender` before it sends anything.
    ///
    /// @dev NO CHAIN-TYPE CHECK HERE, BECAUSE THERE IS NOTHING TO CHECK. A `uint256` chain
    ///      id is an `eip155` reference by construction, so this overload can only ever
    ///      name an EVM destination. The envelope-taking overloads are where the pairing
    ///      has to be enforced.
    function bootstrap(uint256 destinationChainId, Call[] calldata calls)
        external
        payable
        onlyAccountOwner
    {
        _bootstrapCalls(_evmKey(destinationChainId), calls, "");
    }

    function bootstrap(
        uint256 destinationChainId,
        Call[] calldata calls,
        bytes calldata providerData
    ) external payable onlyAccountOwner {
        _bootstrapCalls(_evmKey(destinationChainId), calls, providerData);
    }

    /// @notice `bootstrap`, for a destination named by its ERC-7930 identifier.
    function bootstrapTo(bytes calldata destinationChainIdentifier, Call[] calldata calls)
        external
        payable
        onlyAccountOwner
    {
        _bootstrapCalls(_typedKey(destinationChainIdentifier), calls, "");
    }

    function bootstrapTo(
        bytes calldata destinationChainIdentifier,
        Call[] calldata calls,
        bytes calldata providerData
    ) external payable onlyAccountOwner {
        _bootstrapCalls(_typedKey(destinationChainIdentifier), calls, providerData);
    }

    /// @notice `bootstrap`, in the portable form — for standing this account up on Solana,
    ///         Sui, Starknet, or anything else with no `Call`.
    ///
    /// @dev THE PAIRING IS ENFORCED HERE, NOT AT THE TRANSCEIVER. This is the last point
    ///      that holds the ERC-7930 envelope; downstream everything speaks chainKeys, which
    ///      are hashes and cannot be asked what chain type they came from.
    function bootstrapTo(
        bytes calldata destinationChainIdentifier,
        bytes[] calldata elements
    ) external payable onlyAccountOwner {
        _bootstrapElements(_opaqueKey(destinationChainIdentifier), elements, "");
    }

    function bootstrapTo(
        bytes calldata destinationChainIdentifier,
        bytes[] calldata elements,
        bytes calldata providerData
    ) external payable onlyAccountOwner {
        _bootstrapElements(_opaqueKey(destinationChainIdentifier), elements, providerData);
    }

    /* ============================== destination keys =========================== */

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

    /// @dev And the portable form only reaches one that does not — an EVM receiver decodes
    ///      `Call[]` and only `Call[]`, so opaque elements would arrive undeliverable.
    function _opaqueKey(bytes calldata identifier) private pure returns (bytes32) {
        if (identifier.length == 0) revert NoDestination();
        if (Payload.isTypedDestination(identifier)) {
            revert OpaquePayloadToEvmDestination();
        }
        return ChainKey.fromIdentifier(identifier);
    }

    /* ================================= plumbing ================================ */

    function _sendCalls(bytes32 chainKey, Call[] calldata calls, bytes memory providerData)
        private
    {
        _dispatch(chainKey, Payload.encodeCalls(calls), providerData);
    }

    function _sendElements(
        bytes32 chainKey,
        bytes[] calldata elements,
        bytes memory providerData
    ) private {
        _dispatch(chainKey, Payload.encodeElements(elements), providerData);
    }

    function _bootstrapCalls(
        bytes32 chainKey,
        Call[] calldata calls,
        bytes memory providerData
    ) private {
        if (transceiver == address(0)) revert NoTransceiver();
        ITransceiverBootstrap(transceiver).bootstrap{value: msg.value}(
            chainKey, _owner(), accountSalt, calls, providerData
        );
    }

    function _bootstrapElements(
        bytes32 chainKey,
        bytes[] calldata elements,
        bytes memory providerData
    ) private {
        if (transceiver == address(0)) revert NoTransceiver();
        ITransceiverBootstrap(transceiver).bootstrapElements{value: msg.value}(
            chainKey, _owner(), accountSalt, elements, providerData
        );
    }

    /* ================================= execute ================================= */

    /// @notice Run a payload on THIS chain, with no bridge and no commitment.
    ///
    /// @dev PAYABLE, AND THE VALUE GOES STRAIGHT THROUGH to the receiver, which spends it
    ///      per the `uint256 value` inside each committed call element. Anything the
    ///      payload does not spend stays in the receiver — it is at a deterministic address
    ///      the owner controls, so it is recoverable by a later payload rather than lost.
    ///
    /// @dev IT TAKES NO DESTINATION, BECAUSE IT CANNOT HAVE ONE. There is no bridge in the
    ///      path; the calls run here, in this contract, in this transaction.
    ///
    /// @dev IT RUNS THEM ITSELF RATHER THAN THROUGH A LOCAL RECEIVER. There is no receiver
    ///      on this chain to run them in: a transmitter and its receivers share one
    ///      address across chains, and an address holds one contract — so on Ethereum that
    ///      address is the transmitter. `HubTransceiverBase` has no `createReceiver` to
    ///      call, which is what makes that a structural fact rather than a convention.
    ///
    ///      The two ends therefore share `Executor` rather than one calling the other. A
    ///      payload authorized by the owner here and a payload authorized by a commitment
    ///      there run through the same loop, the same policy check, and the same
    ///      all-or-nothing rule.
    ///
    /// @dev IT TAKES `Call[]` ONLY. This path never crosses a bridge, so the destination is
    ///      this EVM chain by construction and there is no opaque payload it could
    ///      usefully carry. The opaque overloads on `commit`/`commitTo` remain, because
    ///      those approve payloads for destinations this contract cannot execute on.
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
    ///      later, `send` a payload whose one element is this. It arrives, executes, and
    ///      stores the hash; anyone supplies the matching array to `finalize` afterwards.
    ///      Nothing on the wire distinguishes it from any other payload, which is why
    ///      there is no message-type tag anywhere in the protocol.
    ///
    /// @dev The receiver accepts a self-call because the only way to produce
    ///      `msg.sender == address(this)` there is through `_execute`, reachable only from
    ///      an authenticated inbound message or a gated `execute`.
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

    /* ================================== cancel ================================= */

    /// @notice The call that withdraws approval `index` on a receiver, for inclusion in a
    ///         payload bound for that receiver's chain.
    ///
    /// @dev `pure`, so the payload a signer reviews is the payload that executes. The
    ///      receiver accepts a self-call here for the same reason it does for `commit`:
    ///      `msg.sender == address(this)` is reachable only through `_execute`, which
    ///      needs an authenticated inbound message or a gated `execute` to run at all.
    /// @dev CANCELLATION IS INHERENTLY REMOTE, because approvals are. A transmitter holds
    ///      no queue — it executes directly — so there is nothing local to withdraw. This
    ///      builds the element that withdraws one on the receiver's own chain, to be
    ///      carried in a payload once the transport can carry one.
    ///
    /// @dev THE `expected` HASH EARNS ITS KEEP HERE. This call is built when the payload
    ///      is approved and executes whenever it lands, so the queue can have moved in
    ///      between, and nobody is watching the transaction when it runs. Naming the
    ///      approval as well as the slot makes a stale index revert instead of withdrawing
    ///      whatever happens to sit there now.
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

    /// @notice The commitment the `bytes[]` overload would produce for these calls on that
    ///         chain — and the value to pass to the `bytes32` overload.
    ///
    /// @dev `pure`, so it runs off-chain against the exact array the signers reviewed.
    ///      This is what makes the private overload usable: the array is checked here,
    ///      the digest is what gets approved, and nothing on this chain reveals which was
    ///      which. It is also what `predictReceiver` feeds into, so the receiver address
    ///      can be pinned inside the payload it is going to execute.
    function commitmentFor(uint256 destinationChainId, bytes[] calldata calls)
        public
        pure
        returns (bytes32)
    {
        return Commitment.hashCalls(ChainKey.forEvm(destinationChainId), calls);
    }

    /// @notice `commitmentFor`, with the calls supplied in typed form.
    /// @dev EQUAL TO THE OPAQUE OVERLOAD FOR THE SAME PAYLOAD. That is what lets a signer
    ///      review typed calls and approve a digest the destination will match against
    ///      whichever form the message actually carried.
    function commitmentFor(uint256 destinationChainId, Call[] memory calls)
        public
        pure
        returns (bytes32)
    {
        return Commitment.hashCalls(ChainKey.forEvm(destinationChainId), calls);
    }

    /// @notice `commitmentFor`, for a destination named by its ERC-7930 identifier and
    ///         hashing with `scheme`.
    ///
    /// @dev `view` RATHER THAN `pure`, AND ONE SCHEME IS WHY. `Blake2b256` reaches the
    ///      EIP-152 precompile through `staticcall`, which Solidity forbids inside `pure`,
    ///      so the whole dispatching function loses `pure` — the same tax `IVmDeriver`
    ///      already pays for the same precompile. It changes nothing in practice: this is
    ///      read through `eth_call` when a signer checks a payload, where no gas is
    ///      charged and `view` is as good as `pure`.
    ///
    /// @dev A scheme this chain cannot compute reverts with `SchemeNotComputable` rather
    ///      than falling back. For those destinations the digest is built off-chain and
    ///      approved through `commitTo(bytes,bytes32)`.
    function commitmentForChain(
        bytes calldata destinationChainIdentifier,
        Scheme scheme,
        bytes[] calldata calls
    ) public view returns (bytes32) {
        return Commitment.hashElements(
            scheme, ChainKey.fromIdentifier(destinationChainIdentifier), calls
        );
    }

    /// @notice `commitmentForChain`, with the calls supplied in typed form.
    function commitmentForChain(
        bytes calldata destinationChainIdentifier,
        Scheme scheme,
        Call[] memory calls
    ) public view returns (bytes32) {
        return Commitment.hashCalls(
            scheme, ChainKey.fromIdentifier(destinationChainIdentifier), calls
        );
    }

    /// @dev It takes the owner only to emit it. Storing it is the concrete contract's
    ///      job, because that is where the ownership system lives.
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
