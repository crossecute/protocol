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
///      interface for an EVM destination: no chainKey to look up, no eid to know, no
///      per-provider table to keep. The transmitter derives the chainKey purely (see
///      `ChainKey`) and the transceiver turns that into whatever its provider addresses
///      by. `submitTo` is the escape hatch for destinations that have no `uint256` chain
///      id at all.
///
/// @dev OWNERSHIP IS `OwnableUpgradeable`, NOT A HAND-ROLLED FIELD. A transmitter is
///      per-user and its owner is the party that asked the factory for it, so the standard
///      two-step-free `Ownable` semantics are what a user expects, including
///      `transferOwnership`, which a hand-rolled immutable `owner` could not offer.
///      Note this also exposes `renounceOwnership`: renouncing bricks the transmitter,
///      since `submit` is the only way to use one and it is owner-gated.
///
///      This is the opposite choice from `TransceiverBase`, deliberately. A transceiver
///      must compose with a message provider's SDK, which usually brings its own
///      `Ownable`, so it declares `_checkAdmin` and inherits no ownership at all. A
///      transmitter composes with nothing (it is a leaf contract cloned by the factory),
///      so there is no second authority for `Ownable` to collide with.
///
/// @dev IT HOLDS NO REGISTRY POINTER, DELIBERATELY. The chainKey derivation is pure, so
///      nothing here needs to read the directory; the hub transceiver does that lookup
///      once, on the home chain. Keeping the dependency in one contract on one chain is what
///      lets the same transmitter code be a pure commit-and-forward contract.
///
/// @dev THE COMMITMENT IS HASHED FOR THE DESTINATION, NOT FOR HERE. This is the one thing
///      that is easy to get wrong and impossible to notice until a live message fails.
///      `Commitment.hashCalls(calls)` folds in the LOCAL chainKey, and on this contract
///      that is the home chain. The receiver recomputes the same hash on the DESTINATION
///      chain, so a commitment built with the local key can never match. `_submit` therefore hashes
///      with the destination's key, and the chain-binding still does its job: the payload
///      is pinned to exactly one destination and cannot be replayed onto a sibling
///      deployment at the same address.
/// @notice Everything an account needs from the transceiver whose address it already
///         stores. Bootstrap, the quotes that price it, and the route lookup.
///
/// @dev NAMED FOR THE RELATIONSHIP RATHER THAN FOR ONE OF ITS FUNCTIONS. It was
///      `ITransceiverBootstrap` when bootstrap was all it carried; the quotes strained
///      that and `routeTo` breaks it outright. An account holds exactly one transceiver
///      address, so one interface over it is the shape that cannot drift.
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

    /// @dev The quotes live on the same interface as the sends they price, so a
    ///      transmitter cannot hold a reference that can bootstrap but not quote.
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

    /// @notice The message provider's own name for a chain, opaque.
    ///
    /// @dev THIS IS WHY AN ACCOUNT HOLDS NO ROUTE TABLE. The provider's identifier for a
    ///      chain is the one thing about a destination that nothing here can derive, and
    ///      it lives on the transceiver because that is the contract that sends. Reading
    ///      it through this call rather than storing a copy means a msig adding a
    ///      destination is one configuration change, not a migration across every account
    ///      that might want to reach it.
    function routeTo(bytes32 chainKey) external view returns (bytes memory);
}

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
    ///      its own salt, so the value has to travel, and this contract is the only place
    ///      that knows it without a lookup.
    bytes32 public accountSalt;

    /// Destinations this account has already been stood up on.
    ///
    /// @dev IT RECORDS THAT A BOOTSTRAP WAS DISPATCHED, NOT THAT ONE LANDED, and the
    ///      difference is worth stating because nothing on this chain can close it. The
    ///      message is asynchronous, and on a parity chain no report ever comes back: the
    ///      hub derives the receiver's address rather than being told it, which is the
    ///      whole point of `SpokeTransceiverBase.addressesDiverge`. So there is no
    ///      confirmation signal to wait for, and a flag that waited for one would never be
    ///      set on most chains.
    ///
    ///      That is sound because delivery is retryable at the provider rather than here:
    ///      a bootstrap that reverts on arrival can be re-executed by anyone, so the
    ///      message is pending rather than lost. See
    ///      [Failure handling](../../../../docs/message-flow.md#failure-handling).
    ///
    /// @dev THE ONE CASE IT CANNOT SURVIVE is a bootstrap that is permanently undeliverable:
    ///      a route configured to the wrong chain, or a destination that will never accept
    ///      it. This flag then blocks the retry, since `bootstrap` refuses a second attempt.
    ///      Both causes are transceiver misconfiguration, which is write-once and a redeploy
    ///      to correct, so the account was stranded on that destination either way. It is
    ///      recorded here rather than defended against.
    mapping(bytes32 destinationChainKey => bool) private _bootstrapped;

    event TransmitterConfigured(address indexed owner, address indexed transceiver);
    event DestinationBootstrapped(bytes32 indexed destinationChainKey);

    error NoTransceiver();
    /// @dev The recipient names something other than this account. An account's peer is
    ///      itself on every chain, so any other address is either a typo or an attempt to
    ///      route this account's payload somewhere it has no receiver.
    error RecipientIsNotThisAccount(bytes recipient);
    /// @dev A send to a chain this account has not been stood up on has nothing to arrive
    ///      at: the peer address holds no code, so the payload fails on delivery after the
    ///      fee is already spent. Refusing here turns that into a local revert.
    error NotBootstrapped(bytes32 destinationChainKey);
    /// @dev Bootstrap is for a chain with no account. A second one cannot deliver its
    ///      payload anyway, because `CrossProxy` arms exactly once and the receiver's
    ///      `initialize` is single-shot, so it would burn a fee to revert on arrival.
    error AlreadyBootstrapped(bytes32 destinationChainKey);

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

    /// @notice The account's owner. Declared, not implemented: see the note above.
    function _owner() internal view virtual returns (address);

    /// @notice Reverts unless the caller is the owner.
    function _checkOwner() internal view virtual;

    /// @dev NAMED `onlyAccountOwner`, NOT `onlyAccountOwner`, and that is not cosmetic. A
    ///      provider SDK that brings `Ownable` also brings an `onlyAccountOwner` modifier, and
    ///      two base classes declaring one name forces every derived contract to override
    ///      it: the same collision the seam exists to avoid, reappearing one level down.
    ///      `TransceiverBase` sidesteps it the same way, with `onlyAdmin`.
    modifier onlyAccountOwner() {
        _checkOwner();
        _;
    }
    /// @dev `Call[]` is what an EVM receiver executes; nothing else decodes it. Sending it
    ///      to a chain that cannot is a mistake worth catching here rather than on arrival.
    error TypedPayloadToNonEvmDestination();
    /// @dev The mirror. An EVM receiver decodes `Call[]` and only `Call[]`: opaque
    ///      elements would arrive undeliverable, so the portable form is refused for a
    ///      destination that has a typed one.
    error OpaquePayloadToEvmDestination();

    /// @dev Distinct from a bridged delivery, because an execution the owner drove
    ///      directly must be distinguishable on-chain from one a commitment discharged.
    event Executed(address indexed caller, uint256 callCount);

    /* ================================== send =================================== */

    /// @notice Put a payload on the wire for this account's receiver on another chain.
    ///
    /// @dev THE ERC-7786 SOURCE ENTRY POINT, AND NOW THE ONLY ONE. The six `send` and
    ///      `sendTo` overloads are gone: a recipient is a binary interoperable address that
    ///      carries its own chain, so the chain id, the ERC-7930 envelope, and the typed and
    ///      opaque variants all collapse into one argument. What used to be six signatures
    ///      differing only in how the destination was spelled is one signature that takes
    ///      the destination already spelled.
    ///
    /// @dev THE PAYLOAD ARRIVES BUILT, WHICH MOVES ONE CHECK OFF THIS CONTRACT. The old
    ///      overloads took `Call[]` or `bytes[]` and encoded them here, which let this
    ///      contract refuse a typed payload bound for a non-EVM chain and an opaque one
    ///      bound for an EVM chain. `bytes payload` cannot be asked which it is, so that
    ///      pairing is now the caller's to get right, and `payloadForCalls` and
    ///      `payloadForElements` exist so it is at least spelled the same way here as it
    ///      is decoded there.
    ///
    /// @dev THE RECIPIENT MUST BE THIS ACCOUNT'S OWN ADDRESS. An account's peer is itself on
    ///      every chain, which is the property that lets it be its own endpoint, and it is
    ///      derived rather than configured precisely so it cannot be wrong. Taking the
    ///      recipient as an argument reopens that, so the argument is CHECKED rather than
    ///      trusted: a payload addressed anywhere else would arrive at a contract that is
    ///      not this account's receiver, would not accept a `commit` from it, and would not
    ///      match a commitment bound to it.
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

        emit MessageSent(
            bytes32(0),
            Erc7930.encodeEvm(block.chainid, address(this)),
            recipient,
            payload,
            msg.value,
            attributes
        );
        return _dispatch(recipient, payload, attributes);
    }

    /// @notice Whether this account understands a per-send attribute.
    ///
    /// @dev REQUIRED BY ERC-7786 AND ANSWERED BY THE BINDING. This contract has no opinion
    ///      about attributes: they are the provider's vocabulary, decoded where the
    ///      provider is known. The default understands none, which is the honest answer for
    ///      a base with no gateway behind it.
    function supportsAttribute(bytes4) external view virtual returns (bool) {
        return false;
    }

    /// @notice The interoperable address of this account on `destinationChainId`.
    /// @dev The value `sendMessage` expects, so a caller never has to assemble one. It is
    ///      this account's own address by construction; see `sendMessage`.
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
    /// @dev THE ADDRESS CHECK ONLY BINDS WHERE THE ADDRESS IS DERIVABLE, WHICH IS EVM
    ///      PARITY AND NOTHING ELSE. An account's peer is its own address on every chain
    ///      that shares Ethereum's CREATE2 formula, so there `address(this)` is the answer
    ///      and any other recipient is a mistake worth refusing locally. It is NOT the
    ///      answer on zkSync or Tron, whose formulas differ, nor on any non-EVM chain,
    ///      where the account is not a 20-byte address at all. This is the same divergence
    ///      `SpokeTransceiverBase.addressesDiverge` exists to name, seen from the other end.
    ///
    ///      So the check is applied where it holds and skipped where it cannot, rather than
    ///      being weakened to something that holds everywhere and means nothing. On a
    ///      diverging or non-EVM destination the recipient is the caller's to get right,
    ///      and the address the hub recorded for it is in the registry under
    ///      `receiverSlot(chainKey, owner, salt)`.
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
    /// @dev PATH B, AND THE ONLY ONE THE TRANSCEIVER IS IN. There is no peer to send to
    ///      yet, so the message goes to the one contract that already exists on that
    ///      chain. Afterwards every message takes path A and this contract is not involved
    ///      again, which is why the provenance bar gates the FIRST message to a chain
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
    ///
    /// @dev THE PAIRING IS ENFORCED HERE, NOT AT THE TRANSCEIVER. This is the last point
    ///      that holds the ERC-7930 envelope; downstream everything speaks chainKeys, which
    ///      are hashes and cannot be asked what chain type they came from.
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
    /// @dev ITS ARGUMENTS ARE `sendMessage`'s, MINUS THE VALUE, AND THAT IS THE POINT. A
    ///      caller builds the recipient and the payload once, prices them, and sends the
    ///      same three arguments with the answer attached. Anything that changes the price
    ///      is an argument to both, which is what stops the two drifting.
    ///
    /// @dev ERC-7786 DEFINES NO QUOTE, so this is the protocol's own. A gateway that cannot
    ///      answer it leaves `_quoteMessage` reverting `QuoteNotImplemented`, and the
    ///      binding documents the off-chain measurement that replaces it.
    ///
    /// @dev IT CARRIES THE SAME GATES `sendMessage` DOES. A quote that succeeded for a
    ///      message the send would refuse reports the operation ready when it is not, so an
    ///      unbootstrapped destination and a recipient that is not this account fail here
    ///      too.
    ///
    /// @dev UNGATED, UNLIKE THE SEND. It spends nothing, writes nothing, and reveals
    ///      nothing an observer could not compute from the same public state; a signer
    ///      reviewing a payload before the owner submits it has to be able to call it.
    function quoteMessage(
        bytes calldata recipient,
        bytes calldata payload,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        bytes32 chainKey = _requireOwnRecipient(recipient);
        _requireBootstrapped(chainKey);
        return _quote(recipient, payload, attributes);
    }

    /// @notice What standing this account up on a chain that has none would cost.
    ///
    /// @dev IT ASKS THE TRANSCEIVER, BECAUSE THE TRANSCEIVER IS WHAT SENDS. Path B leaves
    ///      from there, with a different envelope and a different counterpart, so pricing it
    ///      against this contract's own `_quoteMessage` would answer for a message nobody
    ///      sends.
    ///
    /// @dev THE PAIR IS NOT CHECKED HERE OR THERE. `bootstrap` proves `(owner, salt)`
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

    /// @dev And the portable form only reaches one that does not: an EVM receiver decodes
    ///      `Call[]` and only `Call[]`, so opaque elements would arrive undeliverable.
    function _opaqueKey(bytes calldata identifier) private pure returns (bytes32) {
        if (identifier.length == 0) revert NoDestination();
        if (Payload.isTypedDestination(identifier)) {
            revert OpaquePayloadToEvmDestination();
        }
        return ChainKey.fromIdentifier(identifier);
    }

    /* ================================= plumbing ================================ */

    /// @dev THE FLAG IS SET BEFORE THE TRANSCEIVER IS CALLED, not after. That call reaches
    ///      a provider endpoint and, through it, arbitrary code; recording first means a
    ///      re-entrant second bootstrap for the same destination meets the flag it would
    ///      otherwise race. If the dispatch reverts the whole transaction unwinds and the
    ///      flag goes with it, so the ordering costs nothing.
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
    /// @dev PAYABLE, AND THE VALUE GOES STRAIGHT THROUGH to the receiver, which spends it
    ///      per the `uint256 value` inside each committed call element. Anything the
    ///      payload does not spend stays in the receiver: it is at a deterministic address
    ///      the owner controls, so it is recoverable by a later payload rather than lost.
    ///
    /// @dev IT TAKES NO DESTINATION, BECAUSE IT CANNOT HAVE ONE. There is no bridge in the
    ///      path; the calls run here, in this contract, in this transaction.
    ///
    /// @dev IT RUNS THEM ITSELF RATHER THAN THROUGH A LOCAL RECEIVER. There is no receiver
    ///      on this chain to run them in: a transmitter and its receivers share one
    ///      address across chains, and an address holds one contract, so at home that
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
    ///      no queue (it executes directly), so there is nothing local to withdraw. This
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

    /// @notice The commitment a payload will need on one EVM destination.
    ///
    /// @dev THIS CONTRACT PREVIEWS EVM DESTINATIONS AND NOTHING ELSE. The portable
    ///      overload that took a `Scheme` was removed: a preview here is frozen with the
    ///      account, so it could only ever answer for primitives that existed when the
    ///      account was created, and it answered from a mutable-looking parameter that no
    ///      longer had a mutable home. Non-EVM destinations are previewed through
    ///      `ChainRegistry.commitmentFor`, where the primitive is a per-chainKey plugin
    ///      and the set of them can grow. See `registry/ICommitmentScheme.sol`.
    ///
    /// @dev WHAT STAYS HERE STAYS BECAUSE IT CANNOT GO STALE. Every chain that executes
    ///      `Call[]` hashes with keccak256, and `ReceiverBase` enforces that exact fold
    ///      from bytecode frozen alongside this. So for an EVM destination the answer is
    ///      fixed for the life of the account, and reading it here rather than from the
    ///      registry is strictly better: it holds without trusting whoever administers a
    ///      plugin table. The split is not a compromise between two surfaces: it is the
    ///      frozen answer where one exists and the extensible answer where none can.
    ///
    /// @dev `pure`, so it runs off-chain against the exact array the signers reviewed. It
    ///      is what `commitmentCall` feeds, so the hash a deferred payload pins is
    ///      checkable before anything is approved.
    function commitmentFor(uint256 destinationChainId, Call[] memory calls)
        public
        pure
        returns (bytes32)
    {
        return Commitment.hashCalls(ChainKey.forEvm(destinationChainId), calls);
    }

    /// @notice `commitmentFor`, for an EVM destination named by its ERC-7930 identifier.
    /// @dev No `Scheme` parameter, and now no sibling that takes one: a typed payload only
    ///      reaches a chain that executes `Call[]`, and every such chain hashes with
    ///      keccak256. There is exactly one primitive this contract can ever need.
    ///
    /// @dev IT STILL REFUSES A NON-EVM IDENTIFIER RATHER THAN DEFERRING TO THE REGISTRY.
    ///      A preview you can compute for a message you cannot send in this shape is a
    ///      trap, and that argument did not change when the other overload left. The
    ///      revert names the mistake; `ChainRegistry.commitmentFor` is where that
    ///      destination is answered.
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
    /// @dev IT IS THE OTHER HALF OF `_refundTo`, AND IT IS LOAD-BEARING ON THE BOOTSTRAP
    ///      PATH. `bootstrap` proves the caller IS this account, so a path B refund comes
    ///      back HERE, and a provider's refund is a plain value transfer: without this the
    ///      transfer reverts and takes the bootstrap with it, which is the one message that
    ///      cannot simply be retried cheaply.
    ///
    /// @dev NOTHING IS STRANDED. This contract sits at an address its owner controls and
    ///      `execute` is payable, so a balance accumulated here is spendable by the next
    ///      payload or recoverable by one written for the purpose. `ReceiverBase` declares
    ///      the same function for the same reason on the other side.
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
