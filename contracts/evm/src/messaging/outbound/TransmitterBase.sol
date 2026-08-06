// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {ICommitFinalize} from "src/messaging/inbound/ReceiverBase.sol";
import {Executor} from "src/messaging/Executor.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Commitment, Scheme} from "src/messaging/Commitment.sol";
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
abstract contract TransmitterBase is OutboundBase, Executor, OwnableUpgradeable {
    /// The local transceiver for this protocol, which carries every message out.
    address public transceiver;

    event TransmitterConfigured(address indexed owner, address indexed transceiver);
    /// @dev Emitted only by the `bytes[]` overloads. The array is already in calldata
    ///      there, so logging it costs a little gas and makes the payload recoverable by
    ///      an indexer rather than only by transaction replay.
    event Disclosed(bytes32 indexed destinationChainKey, bytes32 indexed commitment, bytes[] calls);
    /// @dev The typed twin of `Disclosed`. Kept as a SEPARATE event rather than folded in
    ///      by re-encoding, because an indexer that decodes this one gets named fields
    ///      without knowing the element layout — which is the entire reason a caller
    ///      chooses the typed form.
    event DisclosedCalls(
        bytes32 indexed destinationChainKey, bytes32 indexed commitment, Call[] calls
    );

    error NoTransceiver();

    /// @dev Distinct from a bridged delivery, because an execution the owner drove
    ///      directly must be distinguishable on-chain from one a commitment discharged.
    event Executed(address indexed caller, uint256 callCount);

    /* ================================= commit ================================== */

    /// @notice Approve a payload on one EVM destination by its hash alone.
    ///
    /// @dev PAYABLE FOR THE BRIDGE FEE. A message provider charges to carry the 32 bytes,
    ///      and `_send` reads `msg.value` to pay it. Refunding any excess is the protocol
    ///      adapter's job — LayerZero's `_lzSend` takes a refund address for exactly this.
    ///      The default `_send` reverts, so the base never strands value in a transmitter
    ///      whose protocol forgot to implement sending.
    ///
    /// @dev THE OVERLOAD THAT KEEPS THE PAYLOAD PRIVATE. The array never appears in
    ///      Ethereum calldata, so nothing on this chain reveals what was approved until
    ///      somebody supplies the matching array on the destination and it executes.
    ///      Derive the hash with `commitmentFor`, which is `pure` and can be run
    ///      off-chain against the exact array the signers reviewed.
    ///
    ///      The trade is reviewability: the signers approve thirty-two bytes, and whether
    ///      they can see what those bytes mean depends entirely on their tooling. Use the
    ///      `bytes[]` overload when that matters more than disclosure.
    function commit(uint256 destinationChainId, bytes32 commitment) external payable onlyOwner {
        if (destinationChainId == 0) revert NoDestination();
        _commitOut(ChainKey.forEvm(destinationChainId), commitment);
    }

    /// @notice Approve a payload on one EVM destination by its contents.
    ///
    /// @dev SAME WIRE MESSAGE, DIFFERENT DISCLOSURE. This hashes here and still sends only
    ///      the hash — a transceiver has no way to carry an array — so the destination
    ///      cannot tell the two overloads apart. What differs is on THIS chain: the array
    ///      sits in the approved calldata, permanently recoverable from Ethereum, so the
    ///      approval and the thing approved are one transaction rather than a digest and
    ///      a promise.
    /// @return commitment The hash the destination receiver will require.
    function commit(uint256 destinationChainId, bytes[] calldata calls)
        external
        payable
        onlyOwner
        returns (bytes32 commitment)
    {
        if (destinationChainId == 0) revert NoDestination();
        bytes32 chainKey = ChainKey.forEvm(destinationChainId);
        commitment = Commitment.hashCalls(chainKey, calls);
        emit Disclosed(chainKey, commitment, calls);
        _commitOut(chainKey, commitment);
    }

    /// @notice `commit(uint256,bytes[])` with the calls supplied in typed form.
    ///
    /// @dev IT PRODUCES THE SAME COMMITMENT AS THE OPAQUE OVERLOAD, so the choice is
    ///      purely about what the approving transaction says on Ethereum. Typed calldata
    ///      decodes to named fields in a signing UI; opaque elements do not. Nothing on
    ///      the destination can tell which was used.
    function commit(uint256 destinationChainId, Call[] calldata calls)
        external
        payable
        onlyOwner
        returns (bytes32 commitment)
    {
        if (destinationChainId == 0) revert NoDestination();
        bytes32 chainKey = ChainKey.forEvm(destinationChainId);
        commitment = Commitment.hashCalls(chainKey, calls);
        emit DisclosedCalls(chainKey, commitment, calls);
        _commitOut(chainKey, commitment);
    }

    /// @notice `commit(uint256,bytes32)` for a destination with no EVM chain id.
    ///
    /// @dev THE ONLY OVERLOAD THAT REACHES EVERY DESTINATION, and the reason is the hash.
    ///      The digest is computed off-chain, so it works for a chain whose scheme this
    ///      one cannot run — Starknet, until Poseidon is ported. The disclosing overloads
    ///      below hash here and therefore cannot.
    function commitTo(bytes calldata destinationChainIdentifier, bytes32 commitment)
        external
        payable
        onlyOwner
    {
        if (destinationChainIdentifier.length == 0) revert NoDestination();
        _commitOut(ChainKey.fromIdentifier(destinationChainIdentifier), commitment);
    }

    /// @notice `commit(uint256,bytes[])` for a destination with no EVM chain id.
    ///
    /// @dev IT TAKES THE SCHEME, AND THAT IS THE WHOLE POINT OF THE PARAMETER. This
    ///      overload exists for Solana, Sui, Starknet, TON — chains that do not all hash
    ///      the way the EVM does. Applying keccak256 unconditionally would return a
    ///      perfectly well-formed commitment that a destination hashing with anything else
    ///      could never match, discoverable only on a live message.
    ///
    ///      The scheme is a PARAMETER rather than a registry lookup, for two reasons: this
    ///      contract holds no registry pointer by design, and a parameter puts the scheme
    ///      in the calldata the signers approve — which is right, because the scheme is
    ///      part of what makes the digest mean anything on the far side.
    ///
    ///      Getting it wrong still fails closed: the destination recomputes with its own
    ///      scheme and simply does not match. That is the same failure mode as building a
    ///      commitment with the local chainKey instead of the destination's.
    function commitTo(
        bytes calldata destinationChainIdentifier,
        Scheme scheme,
        bytes[] calldata calls
    ) external payable onlyOwner returns (bytes32 commitment) {
        if (destinationChainIdentifier.length == 0) revert NoDestination();
        bytes32 chainKey = ChainKey.fromIdentifier(destinationChainIdentifier);
        commitment = Commitment.hashElements(scheme, chainKey, calls);
        emit Disclosed(chainKey, commitment, calls);
        _commitOut(chainKey, commitment);
    }

    /// @notice `commitTo(bytes,Scheme,bytes[])` with the calls supplied in typed form.
    /// @dev Available for a non-EVM destination, and deliberately so: `Call[]` is how the
    ///      payload is spelled HERE, and `Commitment` hashes it to the same value the
    ///      opaque elements would produce. Whether the destination can execute those calls
    ///      is a question for its own receiver, exactly as it is for the opaque overload.
    function commitTo(
        bytes calldata destinationChainIdentifier,
        Scheme scheme,
        Call[] calldata calls
    ) external payable onlyOwner returns (bytes32 commitment) {
        if (destinationChainIdentifier.length == 0) revert NoDestination();
        bytes32 chainKey = ChainKey.fromIdentifier(destinationChainIdentifier);
        commitment = Commitment.hashCalls(scheme, chainKey, calls);
        emit DisclosedCalls(chainKey, commitment, calls);
        _commitOut(chainKey, commitment);
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
    function execute(Call[] calldata calls) external payable onlyOwner {
        if (calls.length == 0) revert EmptyExecution();
        emit Executed(msg.sender, calls.length);
        _execute(calls);
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

    function _commitOut(bytes32 destinationChainKey, bytes32 commitment) private {
        if (transceiver == address(0)) revert NoTransceiver();
        _dispatch(destinationChainKey, commitment);
    }

    function __TransmitterBase_init(address owner_, address transceiver_)
        internal
        onlyInitializing
    {
        // `__Ownable_init` rejects the zero owner itself, with `OwnableInvalidOwner`.
        __Ownable_init(owner_);
        if (transceiver_ == address(0)) revert NoTransceiver();
        transceiver = transceiver_;
        emit TransmitterConfigured(owner_, transceiver_);
    }
}
