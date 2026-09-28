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
import {IERC7786GatewaySource} from "src/messaging/IErc7786.sol";

/// @title IAccountTransceiver
/// @notice Everything an account needs from the transceiver whose address it stores.
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

    /// @notice Whether a destination reports its receiver address back, rather than the hub
    ///         deriving it. False wherever Ethereum's CREATE2 holds; true on zkSync, Tron, and
    ///         every non-EVM VM. Asked here because an account holds no registry.
    function reportsReceiver(bytes32 chainKey) external view returns (bool);

    /// @notice The chain identifier the msig configured a destination under, including one
    ///         this account has not bootstrapped yet.
    function routeTo(bytes32 chainKey) external view returns (bytes memory);
}

/// @title TransmitterBase
/// @notice The per-user account on the home chain, and the source-side entry point. One
///         transmitter per protocol per user, routing to every destination.
///
/// @dev The destination is a parameter, not state: one transmitter fans out to every chain,
///      with one receiver per destination.
///
/// @dev Ownership is declared through `_owner`/`_checkOwner` and the modifier is
///      `onlyAccountOwner`, so a provider SDK that brings its own `onlyOwner` does not
///      collide. Every binding answers through `OwnableTransmitter`, whose inherited
///      `renounceOwnership` bricks the account, since every entry point is owner-gated.
///
/// @dev No registry pointer: chainKeys derive purely and the hub does the directory lookups.
///
/// @dev Commitments are hashed with the destination's chainKey, not this chain's:
///      `Commitment.hashCalls` seeds with the chain the receiver recomputes on.
abstract contract TransmitterBase is Initializable, OutboundBase, Executor, IERC7786GatewaySource {
    /// The local transceiver for this protocol, which carries every message out.
    address public transceiver;
    /// The caller-chosen half of this account's CREATE2 salt, stored because `bootstrap` must
    /// state it and an address cannot be reversed into its salt.
    bytes32 public accountSalt;

    event TransmitterConfigured(address indexed owner, address indexed transceiver);
    event DestinationBootstrapped(bytes32 indexed destinationChainKey);
    /// @dev A destination reported an address this account could not derive. Distinct from
    ///      `CounterpartSet`, which also fires for the derived address at bootstrap.
    event DestinationReceiverReported(bytes32 indexed destinationChainKey, bytes receiver);
    /// @dev An execution the owner drove directly, as distinct from one a commitment discharged.
    event Executed(address indexed caller, uint256 callCount);

    error NoTransceiver();
    /// @dev The recipient is not the receiver this account recorded for that chain.
    error RecipientIsNotThisAccount(bytes recipient);
    /// @dev No receiver known on that chain, so a payload would fail on delivery after the fee
    ///      is spent.
    error NotBootstrapped(bytes32 destinationChainKey);
    /// @dev `CrossProxy` arms once, so a second bootstrap would pay a fee to revert on arrival.
    error AlreadyBootstrapped(bytes32 destinationChainKey);
    /// @dev Something that is not this account's transceiver tried to report a receiver.
    error NotTransceiver(address caller);
    /// @dev A receiver's address is reported once; a second report, replayed or hostile, is
    ///      refused. See `_receiverPinned`.
    error ReceiverAlreadyReported(bytes32 destinationChainKey);
    /// @dev `Call[]` is what an EVM receiver executes and nothing else decodes it.
    error TypedPayloadToNonEvmDestination();
    /// @dev An EVM receiver decodes only `Call[]`, so opaque elements would be undeliverable.
    error OpaquePayloadToEvmDestination();

    /// @notice Whether a bootstrap to `destinationChainKey` has been dispatched.
    ///
    /// @dev Dispatched, not landed: on a parity chain no report ever comes back, so nothing
    ///      here could wait for confirmation. Delivery is retryable at the provider, so a
    ///      bootstrap that reverts on arrival is pending, not lost. See
    ///      [Failure handling](../../../../../docs/message-flow.md#failure-handling).
    ///
    /// @dev A permanently undeliverable bootstrap (a wrong route, a destination that never
    ///      accepts it) blocks any retry from here. Both causes are write-once transceiver
    ///      misconfiguration that strands the account anyway.
    function isBootstrapped(bytes32 destinationChainKey) public view returns (bool) {
        return _bootstrapDispatched[destinationChainKey];
    }

    /// @notice Whether this account has been stood up on an EVM chain, by plain chain id.
    function isBootstrappedOn(uint256 destinationChainId) external view returns (bool) {
        return _bootstrapDispatched[ChainKey.forEvm(destinationChainId)];
    }

    /// @notice Whether this account can be sent to on `destinationChainKey` yet.
    /// @dev Equals `isBootstrapped` where the receiver's address is known at dispatch. On
    ///      zkSync, Tron, and every non-EVM VM it stays false until the spoke's report lands.
    function isReachable(bytes32 destinationChainKey) external view returns (bool) {
        return hasCounterpart(destinationChainKey);
    }

    /// @notice This account's receiver on `destinationChainKey`, in that chain's own format.
    function destinationReceiverOn(bytes32 destinationChainKey) external view returns (bytes memory) {
        return counterpartOn(destinationChainKey);
    }

    /// Destinations whose receiver address has been reported and is now fixed.
    ///
    /// @dev Single-shot, with no owner override: the receiver address decides where a payload
    ///      lands. A wrong report is permanent for that destination, which requires the spoke
    ///      on that chain to be compromised or misbuilt, losing the chain either way.
    mapping(bytes32 destinationChainKey => bool) private _receiverPinned;

    /// @notice Destinations this account has dispatched a bootstrap to.
    /// @dev Separate from the counterpart table: on a reporting chain a bootstrap is recorded,
    ///      so a second cannot be paid for, while the destination stays unreachable until its
    ///      receiver is known.
    mapping(bytes32 destinationChainKey => bool) private _bootstrapDispatched;

    /// @notice The transceiver reports where the destination actually created this account's
    ///         receiver.
    ///
    /// @dev Recorded as the counterpart `sendMessage` checks against, since the registry is
    ///      off the send path.
    ///
    /// @dev The transceiver authenticated the origin chain and derived this account from the
    ///      report's `(owner, salt)`, so it cannot aim a report at an account the reporting
    ///      chain did not name. It can report a wrong address for a real account on its own
    ///      chain, which is permanent (see `_receiverPinned`).
    function onDestinationReceiverReported(bytes32 destinationChainKey, bytes calldata receiver) external {
        if (msg.sender != transceiver) revert NotTransceiver(msg.sender);
        // The dispatch is what a report answers: on a reporting chain there is no
        // counterpart until it arrives.
        if (!_bootstrapDispatched[destinationChainKey]) {
            revert NotBootstrapped(destinationChainKey);
        }
        if (_receiverPinned[destinationChainKey]) {
            revert ReceiverAlreadyReported(destinationChainKey);
        }

        _receiverPinned[destinationChainKey] = true;
        _setCounterpart(destinationChainKey, receiver);
        emit DestinationReceiverReported(destinationChainKey, receiver);
    }

    /// @notice Whether a receiver report for this destination has been accepted.
    function isReceiverPinned(bytes32 destinationChainKey) external view returns (bool) {
        return _receiverPinned[destinationChainKey];
    }

    function _requireBootstrapped(bytes32 chainKey) private view {
        if (!hasCounterpart(chainKey)) revert NotBootstrapped(chainKey);
    }

    function _requireNotBootstrapped(bytes32 chainKey) private view {
        if (_bootstrapDispatched[chainKey]) revert AlreadyBootstrapped(chainKey);
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
    /// @dev The ERC-7786 source entry point, and the only send: the recipient is an ERC-7930
    ///      address carrying its own chain.
    ///
    /// @dev A built `bytes` payload cannot be asked whether it holds `Call[]` or opaque
    ///      elements, so pairing it with the right destination type is the caller's job;
    ///      `payloadForCalls` and `payloadForElements` build it. Path B enforces the pairing.
    ///
    /// @dev The recipient must be this account's recorded receiver on that chain; see
    ///      `_requireOwnRecipient`.
    ///
    /// @return sendId Zero when the gateway has taken the message. A binding that returns
    ///         non-zero has a second step to perform and says so in its own NatSpec.
    function sendMessage(bytes calldata recipient, bytes calldata payload, bytes[] calldata attributes)
        external
        payable
        onlyAccountOwner
        returns (bytes32 sendId)
    {
        _requireOwnRecipient(recipient);
        if (payload.length == 0) revert EmptyPayload();

        emit MessageSent(
            bytes32(0), Erc7930.encodeEvm(block.chainid, address(this)), recipient, payload, msg.value, attributes
        );
        return _sendMessage(recipient, payload, attributes, msg.value);
    }

    /// @notice Whether this account understands a per-send attribute. Required by ERC-7786
    ///         and answered by the binding; none here.
    function supportsAttribute(bytes4) external view virtual returns (bool) {
        return false;
    }

    /// @notice The ERC-7930 address of this account on `destinationChainId`: the recipient
    ///         `sendMessage` expects on a parity chain.
    function recipientOn(uint256 destinationChainId) public view returns (bytes memory) {
        return Erc7930.encodeEvm(destinationChainId, address(this));
    }

    /// @notice The ERC-7930 chain identifier for an EVM chain: `bootstrapTo`'s first
    ///         argument, and the value a route is configured under.
    /// @dev `Erc7930` is internal-only, so off-chain callers need this builder to reach the
    ///      `bytes` entry points. It names a chain, where `recipientOn` names an account on one.
    function chainIdentifierFor(uint256 destinationChainId) public pure returns (bytes memory) {
        return _evmIdentifier(destinationChainId);
    }

    /// @notice The wire bytes for an EVM destination, which decodes `Call[]`.
    function payloadForCalls(Call[] calldata calls) public pure returns (bytes memory) {
        return Payload.encodeCalls(calls);
    }

    /// @notice The wire bytes for a destination whose calls this chain cannot express.
    function payloadForElements(bytes[] calldata elements) public pure returns (bytes memory) {
        return Payload.encodeElements(elements);
    }

    /// @notice The recipient must be the receiver this account recorded for that chain.
    ///         Returns the chainKey so nothing parses twice.
    ///
    /// @dev Compares against the stored counterpart, not `address(this)`: the receiver is at
    ///      this address only where Ethereum's CREATE2 holds, not on zkSync, Tron, or a non-EVM
    ///      chain. The whole recipient is compared, so the right account on the wrong chain is
    ///      refused too.
    ///
    /// @dev Checks bootstrap first so an unreached destination reverts `NotBootstrapped`
    ///      rather than `NoRouteFor` from `_recipientOn`.
    function _requireOwnRecipient(bytes calldata recipient) private view returns (bytes32 chainKey) {
        if (recipient.length == 0) revert NoDestination();

        chainKey = ChainKey.fromIdentifier(recipient);
        _requireBootstrapped(chainKey);

        if (keccak256(recipient) != keccak256(_recipientOn(chainKey))) {
            revert RecipientIsNotThisAccount(recipient);
        }
    }

    /* ================================= bootstrap =============================== */

    /// @notice Stand this account up on a chain that has none, and run a payload there.
    ///
    /// @dev Path B: with no receiver yet, the message goes to the transceiver on that chain.
    ///      It passes the owner and salt, from which the destination derives this account's
    ///      address; the transceiver checks they resolve to `msg.sender`.
    ///
    /// @dev The typed/opaque pairing is enforced here, the last point that holds the ERC-7930
    ///      envelope: `_evmIdentifier` is `eip155` by construction, `_typedIdentifier` refuses
    ///      a non-EVM destination, and `_opaqueIdentifier` refuses an EVM one.
    ///
    /// @dev Each bootstrap has a quote with the same arguments minus the value. Pass empty
    ///      `attributes` for the gateway's default.
    function bootstrap(uint256 destinationChainId, Call[] calldata calls, bytes[] calldata attributes)
        external
        payable
        onlyAccountOwner
    {
        _bootstrapCalls(_evmIdentifier(destinationChainId), calls, attributes);
    }

    /// @notice `bootstrap`, for a destination named by its ERC-7930 identifier.
    function bootstrapTo(bytes calldata destinationChainIdentifier, Call[] calldata calls, bytes[] calldata attributes)
        external
        payable
        onlyAccountOwner
    {
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
    /// @dev Takes `sendMessage`'s arguments minus the value and applies its checks, so a
    ///      quote never succeeds for a send that would be refused. Ungated, so a signer can
    ///      price a payload before the owner submits it.
    function quoteMessage(bytes calldata recipient, bytes calldata payload, bytes[] calldata attributes)
        external
        view
        override
        returns (uint256 nativeFee)
    {
        _requireOwnRecipient(recipient);
        if (payload.length == 0) revert EmptyPayload();

        return _quoteMessage(recipient, payload, attributes);
    }

    /// @notice What standing this account up on a chain that has none would cost.
    /// @dev Priced by the transceiver, which sends path B. The `(owner, salt)` check is not
    ///      applied: a quote spends nothing and may be taken before the account exists.
    function quoteBootstrap(uint256 destinationChainId, Call[] calldata calls, bytes[] calldata attributes)
        external
        view
        returns (uint256 nativeFee)
    {
        return _quoteBootstrapCalls(_evmIdentifier(destinationChainId), calls, attributes);
    }

    /// @notice `quoteBootstrap`, for a destination named by its ERC-7930 identifier.
    function quoteBootstrapTo(
        bytes calldata destinationChainIdentifier,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        return _quoteBootstrapCalls(_typedIdentifier(destinationChainIdentifier), calls, attributes);
    }

    /// @notice `quoteBootstrap`, in the portable form.
    function quoteBootstrapTo(
        bytes calldata destinationChainIdentifier,
        bytes[] calldata elements,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        if (transceiver == address(0)) revert NoTransceiver();
        bytes32 chainKey = ChainKey.fromIdentifier(_opaqueIdentifier(destinationChainIdentifier));
        _requireNotBootstrapped(chainKey);

        return
            IAccountTransceiver(transceiver)
                .quoteBootstrapElements(chainKey, _owner(), accountSalt, elements, attributes);
    }

    function _quoteBootstrapCalls(bytes memory identifier, Call[] calldata calls, bytes[] calldata attributes)
        private
        view
        returns (uint256)
    {
        if (transceiver == address(0)) revert NoTransceiver();
        bytes32 chainKey = ChainKey.fromIdentifier(identifier);
        _requireNotBootstrapped(chainKey);

        return IAccountTransceiver(transceiver).quoteBootstrap(chainKey, _owner(), accountSalt, calls, attributes);
    }

    /* =========================== destination identifiers ======================= */

    /// @dev These return the identifier, not the chainKey, because bootstrap records the route
    ///      and a chainKey cannot be reversed into one.

    /// @dev A `uint256` chain id is an `eip155` reference by construction.
    function _evmIdentifier(uint256 chainId) private pure returns (bytes memory) {
        if (chainId == 0) revert NoDestination();
        return Erc7930.encodeEvmChain(chainId);
    }

    /// @dev The typed form only reaches a chain that executes `Call[]`.
    function _typedIdentifier(bytes calldata identifier) private pure returns (bytes calldata) {
        if (identifier.length == 0) revert NoDestination();
        if (!Payload.isTypedDestination(identifier)) {
            revert TypedPayloadToNonEvmDestination();
        }
        return identifier;
    }

    /// @dev And the portable form only reaches one that does not.
    function _opaqueIdentifier(bytes calldata identifier) private pure returns (bytes calldata) {
        if (identifier.length == 0) revert NoDestination();
        if (Payload.isTypedDestination(identifier)) {
            revert OpaquePayloadToEvmDestination();
        }
        return identifier;
    }

    /* =============================== shared code =============================== */

    function _bootstrapCalls(bytes memory identifier, Call[] calldata calls, bytes[] calldata attributes) private {
        bytes32 chainKey = _markBootstrapped(identifier);

        IAccountTransceiver(transceiver).bootstrap{value: msg.value}(chainKey, _owner(), accountSalt, calls, attributes);
    }

    function _bootstrapElements(bytes memory identifier, bytes[] calldata elements, bytes[] calldata attributes)
        private
    {
        bytes32 chainKey = _markBootstrapped(identifier);

        IAccountTransceiver(transceiver).bootstrapElements{value: msg.value}(
            chainKey, _owner(), accountSalt, elements, attributes
        );
    }

    /// @dev Records the destination before the transceiver is called: that call reaches a
    ///      provider endpoint and arbitrary code, so a re-entrant second bootstrap meets the
    ///      record. A revert unwinds it with everything else.
    ///
    /// @dev Records the receiver only where its address is already known (the chain does not
    ///      report). On a reporting chain the destination stays unreachable until the report
    ///      arrives, rather than addressed at a guess.
    function _markBootstrapped(bytes memory identifier) private returns (bytes32 chainKey) {
        if (transceiver == address(0)) revert NoTransceiver();
        chainKey = ChainKey.fromIdentifier(identifier);
        _requireNotBootstrapped(chainKey);

        _bootstrapDispatched[chainKey] = true;
        _setRoute(chainKey, identifier);

        if (!IAccountTransceiver(transceiver).reportsReceiver(chainKey)) {
            _setCounterpart(chainKey, abi.encodePacked(address(this)));
        }

        emit DestinationBootstrapped(chainKey);
    }

    /* ================================= execute ================================= */

    /// @notice Run a payload on THIS chain, with no bridge and no commitment.
    ///
    /// @dev Runs the calls itself: a transmitter and its receivers share one address, so there
    ///      is no receiver at home. Both ends share `Executor`'s loop, policy check, and
    ///      all-or-nothing rule.
    ///
    /// @dev Payable; value passes to the calls, and anything unspent stays at this
    ///      owner-controlled address.
    function execute(Call[] calldata calls) external payable onlyAccountOwner {
        if (calls.length == 0) revert EmptyExecution();
        emit Executed(msg.sender, calls.length);
        _execute(calls);
    }

    /* ============================== payload helpers ============================ */

    /// @notice The call that pins `commitment` on a receiver, for inclusion in a payload
    ///         bound for that receiver's chain.
    /// @dev Committing is a call, not a message kind: a payload whose single element is this
    ///      stores the hash on arrival, and anyone later supplies the array to `finalize`. The
    ///      receiver accepts it as a self-call from `_execute`.
    function commitmentCall(address receiver, bytes32 commitment) public pure returns (Call memory) {
        return Call({target: receiver, value: 0, data: abi.encodeCall(ICommitFinalize.commit, (commitment))});
    }

    /// @notice The call that withdraws an approval on a receiver, for inclusion in a payload
    ///         bound for that receiver's chain.
    /// @dev Names the approval by hash, so it cannot go stale in transit: the approval either
    ///      still exists or the call reverts.
    function cancellationCall(address receiver, bytes32 commitment) public pure returns (Call memory) {
        return Call({target: receiver, value: 0, data: abi.encodeCall(ICancel.cancel, (commitment))});
    }

    /* ================================= preview ================================= */

    /// @notice The commitment a payload will need on one EVM destination.
    ///
    /// @dev EVM destinations only. Every `Call[]` chain hashes with keccak256, which
    ///      `ReceiverBase` enforces from bytecode frozen alongside this, so the answer cannot go
    ///      stale. Non-EVM destinations are previewed through `ChainRegistry.commitmentFor`,
    ///      whose per-chain plugins can grow after this account is frozen.
    ///
    /// @dev `pure`, so it runs off-chain against the exact array the signers reviewed.
    function commitmentFor(uint256 destinationChainId, Call[] memory calls) public pure returns (bytes32) {
        return Commitment.hashCalls(ChainKey.forEvm(destinationChainId), calls);
    }

    /// @notice `commitmentFor`, for an EVM destination named by its ERC-7930 identifier.
    /// @dev Refuses a non-EVM identifier; `ChainRegistry.commitmentFor` answers those.
    function commitmentForChain(bytes calldata destinationChainIdentifier, Call[] memory calls)
        public
        pure
        returns (bytes32)
    {
        if (!Payload.isTypedDestination(destinationChainIdentifier)) {
            revert TypedPayloadToNonEvmDestination();
        }
        return Commitment.hashCalls(ChainKey.fromIdentifier(destinationChainIdentifier), calls);
    }

    /// @notice Accept ETH, so a refunded fee has somewhere to land.
    /// @dev `bootstrap` is called by this account, so a provider's path-B refund comes here;
    ///      without `receive` it would revert the bootstrap.
    receive() external payable {}

    function __TransmitterBase_init(address owner_, address transceiver_, bytes32 salt_) internal onlyInitializing {
        if (transceiver_ == address(0)) revert NoTransceiver();

        transceiver = transceiver_;
        accountSalt = salt_;
        emit TransmitterConfigured(owner_, transceiver_);
    }
}
