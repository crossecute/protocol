// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {ICommitFinalize, ICancel} from "src/messaging/inbound/ReceiverBase.sol";
import {Executor} from "src/messaging/Executor.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Call} from "src/messaging/Call.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {IERC7786GatewaySource} from
    "src/messaging/IErc7786.sol";

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

    /// @notice The chain identifier the MSIG has configured a destination under.
    ///
    /// @dev IT ANSWERS FOR DESTINATIONS AN ACCOUNT HAS NOT REACHED YET, which is the one
    ///      thing the account's own table cannot do: that table is written by `bootstrap`,
    ///      so before the first message to a chain it holds nothing. A caller asking "can
    ///      this account be stood up there" reads it here. Afterwards the two necessarily
    ///      agree, because a chainKey IS `keccak256(identifier)` and one key cannot have two.
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
    Initializable,
    OutboundBase,
    Executor,
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

    event TransmitterConfigured(address indexed owner, address indexed transceiver);
    event DestinationBootstrapped(bytes32 indexed destinationChainKey);
    /// @dev Distinct from `CounterpartSet`, which fires on every write including the
    ///      presumed one at bootstrap. This says a destination reported an address the
    ///      account could not derive, which is the event an operator watches for.
    event DestinationReceiverReported(bytes32 indexed destinationChainKey, bytes receiver);
    /// @dev Distinct from a bridged delivery: an execution the owner drove directly must be
    ///      distinguishable on-chain from one a commitment discharged.
    event Executed(address indexed caller, uint256 callCount);

    error NoTransceiver();
    /// @dev The recipient is not the receiver this account recorded for that chain, so it is
    ///      either a typo or an attempt to route this account's payload somewhere it has no
    ///      receiver.
    error RecipientIsNotThisAccount(bytes recipient);
    /// @dev The peer address on an un-bootstrapped chain holds no code, so the payload fails
    ///      on delivery after the fee is spent. Refusing here makes that a local revert.
    error NotBootstrapped(bytes32 destinationChainKey);
    /// @dev A second bootstrap cannot deliver its payload anyway, because `CrossProxy` arms
    ///      exactly once and the receiver's `initialize` is single-shot, so it would burn a
    ///      fee to revert on arrival.
    error AlreadyBootstrapped(bytes32 destinationChainKey);
    /// @dev Something that is not this account's transceiver tried to report a receiver.
    error NotTransceiver(address caller);
    /// @dev A receiver's address on a chain is established once, at bootstrap, so there is
    ///      no legitimate second report. The OWNER may still correct it; this refuses only
    ///      the remote path, so a replayed or hostile second report is a no-op rather than a
    ///      repoint.
    error ReceiverAlreadyReported(bytes32 destinationChainKey);
    /// @dev `Call[]` is what an EVM receiver executes and nothing else decodes it.
    error TypedPayloadToNonEvmDestination();
    /// @dev The mirror: an EVM receiver decodes `Call[]` and only `Call[]`, so opaque
    ///      elements would arrive undeliverable.
    error OpaquePayloadToEvmDestination();

    /// @notice Whether this account has been stood up on `destinationChainKey`.
    ///
    /// @dev IT IS THE COUNTERPART TABLE, NOT A SEPARATE FLAG. Bootstrap records the receiver
    ///      it is standing up, so "has a receiver recorded there" and "has been bootstrapped
    ///      there" are one fact and cannot disagree.
    ///
    /// @dev IT RECORDS THAT A BOOTSTRAP WAS DISPATCHED, NOT THAT ONE LANDED, and nothing on
    ///      this chain can close that gap: the message is asynchronous, and on a parity chain
    ///      no report ever comes back, because the hub derives the receiver's address rather
    ///      than being told it. A flag that waited for confirmation would never be set on
    ///      most chains. That is sound because delivery is retryable at the provider, so a
    ///      bootstrap that reverts on arrival is pending rather than lost. See
    ///      [Failure handling](../../../../../docs/message-flow.md#failure-handling).
    ///
    /// @dev THE ONE CASE IT CANNOT SURVIVE is a permanently undeliverable bootstrap: a route
    ///      configured to the wrong chain, or a destination that will never accept it. This
    ///      then blocks the retry. Both causes are transceiver misconfiguration, which is
    ///      write-once and a redeploy to correct, so the account was stranded either way.
    function isBootstrapped(bytes32 destinationChainKey) public view returns (bool) {
        return hasCounterpart(destinationChainKey);
    }

    /// @notice Whether this account has been stood up on an EVM chain, by plain chain id.
    function isBootstrappedOn(uint256 destinationChainId) external view returns (bool) {
        return hasCounterpart(ChainKey.forEvm(destinationChainId));
    }

    /// @notice This account's receiver on `destinationChainKey`, in that chain's own format.
    /// @dev `counterpartOn` names the same value; this is the name that says what it IS here.
    function destinationReceiverOn(bytes32 destinationChainKey)
        external
        view
        returns (bytes memory)
    {
        return counterpartOn(destinationChainKey);
    }

    /// Destinations whose receiver address has been reported and is now fixed.
    ///
    /// @dev THE REPORT IS SINGLE-SHOT, AND THERE IS NO SECOND WAY IN. A receiver's address
    ///      is established once, when the spoke creates it, so a second report is a replay
    ///      or a repoint and neither is something a remote chain gets to do. There is no
    ///      owner override either: an account's peer decides where a payload LANDS, so it is
    ///      the one value the protocol will not let anyone choose after the fact.
    ///
    ///      The cost is that a wrong report is permanent for that destination, which is the
    ///      trade every other write-once value here makes. It is bounded by what has to go
    ///      wrong first: the spoke transceiver on that chain must be compromised or
    ///      misbuilt, and that chain is lost either way.
    mapping(bytes32 destinationChainKey => bool) private _receiverPinned;

    /// @notice The transceiver reports where the destination actually created this account's
    ///         receiver.
    ///
    /// @dev THE REPORT LANDS ON THE ACCOUNT IT IS ABOUT, which is the only contract that
    ///      reads it, and it lands as the counterpart `sendMessage` checks against. Filing it
    ///      in the registry instead would put it somewhere nothing on the send path can see,
    ///      since the registry is deliberately out of that path, and a diverging chain would
    ///      stay unreachable however faithfully its address was recorded.
    ///
    /// @dev THE TRANSCEIVER IS TRUSTED FOR THIS AND NOTHING ELSE, and the bar it has already
    ///      cleared is what makes that acceptable. It authenticated the origin chain, and it
    ///      derived this account's address from the `(owner, salt)` the report stated, so it
    ///      cannot direct a report at an account the reporting chain did not name. What it
    ///      CAN do is report a wrong address for a real account on its own chain, and that
    ///      is permanent: see `_receiverPinned` for why there is no override.
    function onDestinationReceiverReported(
        bytes32 destinationChainKey,
        bytes calldata receiver
    ) external {
        if (msg.sender != transceiver) revert NotTransceiver(msg.sender);
        if (!hasCounterpart(destinationChainKey)) {
            revert NotBootstrapped(destinationChainKey);
        }
        if (_receiverPinned[destinationChainKey]) {
            revert ReceiverAlreadyReported(destinationChainKey);
        }

        _receiverPinned[destinationChainKey] = true;
        _setCounterpart(destinationChainKey, receiver);
        emit DestinationReceiverReported(destinationChainKey, receiver);
    }

    /// @notice Whether this destination's receiver is still the bootstrap presumption.
    function isReceiverPinned(bytes32 destinationChainKey) external view returns (bool) {
        return _receiverPinned[destinationChainKey];
    }

    function _requireBootstrapped(bytes32 chainKey) private view {
        if (!hasCounterpart(chainKey)) revert NotBootstrapped(chainKey);
    }

    function _requireNotBootstrapped(bytes32 chainKey) private view {
        if (hasCounterpart(chainKey)) revert AlreadyBootstrapped(chainKey);
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
    ///      there. Path B still holds the envelope and does enforce it: see `_typedIdentifier`.
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
        _requireOwnRecipient(recipient);
        if (payload.length == 0) revert EmptyPayload();

        emit MessageSent(
            bytes32(0),
            Erc7930.encodeEvm(block.chainid, address(this)),
            recipient,
            payload,
            msg.value,
            attributes
        );
        return _sendMessage(recipient, payload, attributes, msg.value);
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

    /// @notice The ERC-7930 chain identifier for an EVM chain: `bootstrapTo`'s first
    ///         argument, and the value a route is configured under.
    ///
    /// @dev THE TWIN OF `recipientOn`, AND IT EXISTS FOR THE SAME REASON. Every entry point
    ///      here that takes `bytes` has a builder that produces it, because `Erc7930` is a
    ///      library of `internal` functions and is therefore not callable off-chain at all: a
    ///      caller without this would have to reimplement the encoding to reach `bootstrapTo`,
    ///      and an interoperable address got wrong is a message addressed into the void.
    ///
    /// @dev IT NAMES A CHAIN, WHERE `recipientOn` NAMES AN ACCOUNT ON ONE, which is the whole
    ///      difference between the two entry points they serve. Path A addresses this
    ///      account's receiver; path B addresses a chain that has no account yet.
    ///
    /// @dev `bootstrap(uint256, ...)` MAKES THIS OPTIONAL FOR EVM DESTINATIONS, deliberately.
    ///      This is for a caller that wants one spelling for every destination, and it is the
    ///      only spelling available for a chain with no `uint256` id at all.
    function chainIdentifierFor(uint256 destinationChainId)
        public
        pure
        returns (bytes memory)
    {
        return _evmIdentifier(destinationChainId);
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

    /// @notice The recipient must be the receiver this account recorded for that chain.
    ///         Returns the chainKey so nothing parses twice.
    ///
    /// @dev IT COMPARES AGAINST THE STORED COUNTERPART, NOT AGAINST `address(this)`, and that
    ///      is what makes the check both correct and universal. An account's receiver shares
    ///      its address wherever Ethereum's CREATE2 formula holds, so deriving it looked
    ///      free; it is NOT its address on zkSync or Tron, whose formulas differ, nor on any
    ///      non-EVM chain, where the account is not a 20-byte address at all. A derived check
    ///      therefore had to be skipped off `eip155` (leaving the recipient unchecked) and
    ///      was actively WRONG on the diverging EVM chains, which are `eip155` and so kept a
    ///      check that could never pass. Comparing against what `bootstrap` recorded, and
    ///      what a report from that chain replaces it with, holds everywhere.
    ///
    /// @dev IT COMPARES THE WHOLE RECIPIENT, so the chain half is checked too: a payload
    ///      addressed to the right account on the wrong chain is refused here rather than
    ///      arriving somewhere its commitment cannot match.
    ///
    /// @dev THE BOOTSTRAP CHECK RUNS INSIDE IT, so both entry points get it in the right
    ///      order: `_recipientOn` would also revert on an unrecorded destination, but as
    ///      `NoRouteFor`, which describes the storage rather than the mistake.
    function _requireOwnRecipient(bytes calldata recipient)
        private
        view
        returns (bytes32 chainKey)
    {
        if (recipient.length == 0) revert NoDestination();

        chainKey = ChainKey.fromIdentifier(recipient);
        // Before the comparison, so an unreachable destination says so plainly rather than
        // failing as an empty expectation inside `_recipientOn`.
        _requireBootstrapped(chainKey);

        if (keccak256(recipient) != keccak256(_recipientOn(chainKey))) {
            revert RecipientIsNotThisAccount(recipient);
        }
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
    /// @dev THE PAIRING CHECK LIVES HERE, unlike on path A, because these three still hold
    ///      typed calls and the ERC-7930 envelope: `_evmIdentifier` is `eip155` by
    ///      construction, `_typedIdentifier` refuses a non-EVM destination, and
    ///      `_opaqueIdentifier` refuses an EVM one.
    ///      This is the last point that holds the envelope; downstream everything speaks
    ///      chainKeys, which are hashes and cannot be asked what they came from.
    ///
    /// @dev THERE ARE THREE OF THESE AND EXACTLY THREE QUOTES, WHICH IS NOT A COINCIDENCE.
    ///      Only two things about a bootstrap can vary: how the destination is spelled, and
    ///      whether its calls are typed or opaque. `attributes` is not a third: it carries
    ///      destination gas, which changes the price, and the rule every quote here states is
    ///      that its arguments are its send's minus the value. A no-attributes overload would
    ///      be a send with no quote of matching arity, to save a caller writing
    ///      `new bytes[](0)`. Pass an empty array to mean "the gateway's default"; that is a
    ///      choice worth making visibly.
    function bootstrap(
        uint256 destinationChainId,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external payable onlyAccountOwner {
        _bootstrapCalls(_evmIdentifier(destinationChainId), calls, attributes);
    }

    /// @notice `bootstrap`, for a destination named by its ERC-7930 identifier.
    function bootstrapTo(
        bytes calldata destinationChainIdentifier,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external payable onlyAccountOwner {
        _bootstrapCalls(_typedIdentifier(destinationChainIdentifier), calls, attributes);
    }

    /// @notice `bootstrap`, in the portable form: for standing this account up on Solana,
    ///         Sui, Starknet, or anything else with no `Call`.
    function bootstrapTo(
        bytes calldata destinationChainIdentifier,
        bytes[] calldata elements,
        bytes[] calldata attributes
    ) external payable onlyAccountOwner {
        _bootstrapElements(_opaqueIdentifier(destinationChainIdentifier), elements, attributes);
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
    ) external view override returns (uint256 nativeFee) {
        _requireOwnRecipient(recipient);
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
        return _quoteBootstrapCalls(_evmIdentifier(destinationChainId), calls, attributes);
    }

    /// @notice `quoteBootstrap`, for a destination named by its ERC-7930 identifier.
    function quoteBootstrapTo(
        bytes calldata destinationChainIdentifier,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        return _quoteBootstrapCalls(
            _typedIdentifier(destinationChainIdentifier), calls, attributes
        );
    }

    /// @notice `quoteBootstrap`, in the portable form.
    function quoteBootstrapTo(
        bytes calldata destinationChainIdentifier,
        bytes[] calldata elements,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        if (transceiver == address(0)) revert NoTransceiver();
        bytes32 chainKey =
            ChainKey.fromIdentifier(_opaqueIdentifier(destinationChainIdentifier));
        _requireNotBootstrapped(chainKey);

        return IAccountTransceiver(transceiver).quoteBootstrapElements(
            chainKey, _owner(), accountSalt, elements, attributes
        );
    }

    function _quoteBootstrapCalls(
        bytes memory identifier,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) private view returns (uint256) {
        if (transceiver == address(0)) revert NoTransceiver();
        bytes32 chainKey = ChainKey.fromIdentifier(identifier);
        _requireNotBootstrapped(chainKey);

        return IAccountTransceiver(transceiver).quoteBootstrap(
            chainKey, _owner(), accountSalt, calls, attributes
        );
    }

    /* =========================== destination identifiers ======================= */

    /// @dev THEY RETURN THE IDENTIFIER, NOT THE CHAINKEY, because bootstrap records the
    ///      route as well as the receiver and a chainKey is a hash that cannot be reversed
    ///      into one. The chainKey is derived from the identifier where it is needed.

    /// @dev A `uint256` chain id is an `eip155` reference by construction, so there is no
    ///      chain type to check.
    function _evmIdentifier(uint256 chainId) private pure returns (bytes memory) {
        if (chainId == 0) revert NoDestination();
        return Erc7930.encodeEvmChain(chainId);
    }

    /// @dev The typed form only reaches a chain that executes `Call[]`.
    function _typedIdentifier(bytes calldata identifier)
        private
        pure
        returns (bytes calldata)
    {
        if (identifier.length == 0) revert NoDestination();
        if (!Payload.isTypedDestination(identifier)) {
            revert TypedPayloadToNonEvmDestination();
        }
        return identifier;
    }

    /// @dev And the portable form only reaches one that does not.
    function _opaqueIdentifier(bytes calldata identifier)
        private
        pure
        returns (bytes calldata)
    {
        if (identifier.length == 0) revert NoDestination();
        if (Payload.isTypedDestination(identifier)) {
            revert OpaquePayloadToEvmDestination();
        }
        return identifier;
    }

    /* ================================= plumbing ================================ */

    /// @dev THE FLAG IS SET BEFORE THE TRANSCEIVER IS CALLED. That call reaches a provider
    ///      endpoint and, through it, arbitrary code, so recording first means a re-entrant
    ///      second bootstrap for the same destination meets the flag it would otherwise race.
    ///      If the dispatch reverts the whole transaction unwinds and the flag goes with it,
    ///      so the ordering costs nothing.
    function _bootstrapCalls(
        bytes memory identifier,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) private {
        bytes32 chainKey = _markBootstrapped(identifier);

        IAccountTransceiver(transceiver).bootstrap{value: msg.value}(
            chainKey, _owner(), accountSalt, calls, attributes
        );
    }

    function _bootstrapElements(
        bytes memory identifier,
        bytes[] calldata elements,
        bytes[] calldata attributes
    ) private {
        bytes32 chainKey = _markBootstrapped(identifier);

        IAccountTransceiver(transceiver).bootstrapElements{value: msg.value}(
            chainKey, _owner(), accountSalt, elements, attributes
        );
    }

    /// @dev IT RECORDS THE DESTINATION BEFORE THE TRANSCEIVER IS CALLED, not after. That call
    ///      reaches a provider endpoint and, through it, arbitrary code, so recording first
    ///      means a re-entrant second bootstrap for the same destination meets the state it
    ///      would otherwise race. If the dispatch reverts the whole transaction unwinds and
    ///      the record goes with it, so the ordering costs nothing.
    ///
    /// @dev THE RECEIVER IT RECORDS IS A PRESUMPTION, AND ON MOST CHAINS A CORRECT ONE. An
    ///      account and its receiver share an address wherever Ethereum's CREATE2 formula
    ///      holds, which is every destination but zkSync, Tron, and the non-EVM chains. There
    ///      the value is wrong until the spoke's own report replaces it, and until then a
    ///      send is refused rather than misdelivered.
    function _markBootstrapped(bytes memory identifier)
        private
        returns (bytes32 chainKey)
    {
        if (transceiver == address(0)) revert NoTransceiver();
        chainKey = ChainKey.fromIdentifier(identifier);
        _requireNotBootstrapped(chainKey);

        _setRoute(chainKey, identifier);
        _setCounterpart(chainKey, abi.encodePacked(address(this)));
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

    /// @notice The call that withdraws an approval on a receiver, for inclusion in a payload
    ///         bound for that receiver's chain.
    ///
    /// @dev CANCELLATION IS INHERENTLY REMOTE, because approvals are: a transmitter executes
    ///      directly and holds nothing to withdraw.
    ///
    /// @dev IT NAMES THE APPROVAL ITSELF, WHICH IS WHY THIS SURVIVES THE TRIP. The element is
    ///      built when the payload is approved and executes whenever it lands, with nobody
    ///      watching in between. A hash cannot go stale the way a position could: it either
    ///      still has an approval, or the call reverts.
    function cancellationCall(address receiver, bytes32 commitment)
        public
        pure
        returns (Call memory)
    {
        return Call({
            target: receiver,
            value: 0,
            data: abi.encodeCall(ICancel.cancel, (commitment))
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
