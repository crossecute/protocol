// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Call, Calls} from "src/messaging/Call.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Executor} from "src/messaging/Executor.sol";

/// @notice Two-step execution: pin a hash now, supply the matching array later.
/// @dev `commit` is gated and `finalize` is not, and that is the whole point: the
///      approval lives in the hash, so the only array that does anything is the one
///      already approved and whoever relays it is irrelevant.
///
/// @dev IT TAKES `Call[]`, AND ONLY `Call[]`. An EVM receiver executes EVM calls; there is
///      no payload it can run that is not `(target, value, data)`, so an opaque overload
///      would accept elements it could only decode into this shape anyway or revert on.
///      The commitment stays defined over opaque elements (that layer must be
///      VM-agnostic, and `Commitment` hashes both forms to one value), but the ENTRY
///      POINT does not, because this contract only ever runs on an EVM chain.
interface ICommitFinalize {
    function commit(bytes32 commitment) external returns (uint256 index);
    function cancel(uint256 index, bytes32 expected) external;
    function finalize(Call[] calldata calls) external;
    function finalize(Call[][] calldata batches) external;
}

/// @notice One-step execution: run this array, no hash comparison.
/// @dev THE MIRROR IMAGE OF `ICommitFinalize`, and the trade is exact. `finalize` may be
///      permissionless BECAUSE it checks the payload against an approved hash; `execute`
///      skips that check, so it must be gated on the caller instead. Exactly one of the
///      two constraints has to hold, and each interface picks a different one.
interface IExecute {
    function execute(Call[] calldata calls) external payable;
}

/// @notice What a transceiver needs from the receiver it clones and reuses.
interface IReceiverInit is ICommitFinalize, IExecute {
    function initialize(address sourceTransmitter, Call[] calldata calls) external;
}

/// @title ReceiverBase
/// @notice The destination-side half of commit/finalize. Exactly ONE receiver per
///         transmitter per destination, deployed as a minimal proxy by the transceiver
///         and reused for every payload that transmitter ever sends.
///
/// @dev BECAUSE THE RECEIVER IS LONG-LIVED, approvals are a QUEUE rather than a slot. With
///      a single slot a second commit would have to revert while one was still pending, so
///      one un-finalized approval would block every later one from even being recorded.
///
/// @dev THE QUEUE IS ORDERED, AND EXECUTION IS STRICTLY FIFO. `finalize` will only accept
///      the array matching the OLDEST outstanding approval. That is a deliberate
///      constraint rather than an implementation artifact: a multisig payload sequence
///      usually means something only in order (approve then transfer, set then use), and
///      a queue that executed out of order would let a relayer choose which half of that
///      pair lands first.
///
///      The cost is head-of-line blocking, and it is worth naming plainly. A payload that
///      can never execute (a target that always reverts, a call that is now invalid)
///      would otherwise stall every approval behind it forever. `cancel` is the escape
///      hatch, and the two features are load-bearing for each other: ordering is only
///      safe because a stuck entry can be removed, and cancellation is only necessary
///      because execution is ordered. Neither should be removed without the other.
///
/// @dev THE QUEUE IS APPEND-ONLY. An entry is never moved, so the index `commit` returns
///      names that approval for the life of the receiver, which is what lets `cancel`
///      take an index and not race against anything. A cancelled entry is zeroed in
///      place; a consumed one keeps its value and is passed by the head pointer, so the
///      two remain distinguishable on-chain after the fact.
///
/// @dev EVERYTHING IS STORAGE, NOT IMMUTABLE. The spec describes the transmitter and
///      transceiver as immutables, but a receiver is an EIP-1167 clone: immutables live
///      in the implementation's bytecode, so every clone would share one value. They are
///      therefore set once in `initialize`, which the `initializer` modifier makes
///      single-shot.
///
/// @dev THE COMMITMENT IS CHAIN-BOUND. `Commitment.hashCalls` folds `block.chainid` in as
///      the first element, so a call array approved for one chain cannot be finalized
///      here. Receivers are deployed at deterministic addresses across chains, which is
///      exactly the situation where a cross-chain replay would otherwise work.
abstract contract ReceiverBase is
    Executor,
    Initializable,
    ReentrancyGuardUpgradeable,
    IReceiverInit
{
    /// The transmitter this receiver answers to. Set once, at initialization.
    address public sourceTransmitter;
    /// The transceiver that cloned this receiver. Named to avoid colliding with
    /// `TransmitterBase.transceiver`, which means the opposite direction: a Transceiver
    /// inherits both.
    address public parentTransceiver;
    /// The approvals, oldest first. Append-only; a cancelled entry is zeroed in place.
    bytes32[] private _commitments;
    /// Index of the next approval `finalize` will require. Everything below it is spent.
    uint256 private _head;

    event ReceiverInitialized(address indexed sourceTransmitter, address indexed transceiver);
    event ReceiverCommitted(uint256 indexed index, bytes32 commitment);
    event ReceiverCancelled(uint256 indexed index, bytes32 commitment);
    event ReceiverFinalized(uint256 indexed index, bytes32 commitment, uint256 callCount);
    event ReceiverExecuted(address indexed caller, uint256 callCount);
    /// @dev A payload that arrived over the wire and ran on arrival, as distinct from one
    ///      a commitment discharged or the owner drove locally.
    event ReceiverDelivered(uint256 callCount);

    /// @dev The commit/finalize vocabulary. Declared here because this is the only
    ///      contract that holds a commitment: a shared base for three words would be a
    ///      file whose whole job is to be inherited.
    error NothingCommitted();
    error CommitmentMismatch();
    /// @dev Zero marks a cancelled queue entry and an absent one alike, so it can never
    ///      be an approval.
    error ZeroCommitment();

    error NotSourceTransmitter();
    error NotAuthorizedCommitter();
    error ZeroTransmitter();
    error IndexOutOfRange(uint256 index);
    /// @dev Already executed. Cancelling it would suggest the payload can still be
    ///      stopped, and it cannot: it already ran.
    error AlreadyConsumed(uint256 index);
    error AlreadyCancelled(uint256 index);
    /// @dev The entry at that index is not the approval the caller meant to withdraw.
    ///      Carries both so the caller can see what it would have removed.
    error CancelMismatch(uint256 index, bytes32 pending, bytes32 expected);
    /// @dev An empty batch has nothing to finalize, and silently succeeding would report
    ///      progress the queue did not make.
    error EmptyBatch();

    /// @notice Whether `account` is the transmitter this receiver was created for.
    /// @dev The ownership predicate. Exposed as a view so a caller can check before
    ///      spending gas on a transaction that would revert, and so an off-chain relayer
    ///      can confirm it is talking to the right clone.
    function isSourceTransmitter(address account) public view returns (bool) {
        return account != address(0) && account == sourceTransmitter;
    }

    /// @notice Who may pin a new commitment here.
    /// @dev THREE CALLERS, each for a different reason. The source transmitter is the
    ///      owner, and its arm covers a same-chain deployment where it can reach this
    ///      contract directly. The parent transceiver is what created this receiver, and
    ///      needs the authority only for the bootstrap payload it initializes with: it
    ///      never calls `commit` afterwards. `address(this)` is what a deferred payload
    ///      uses to pin its own hash; see below.
    /// @dev IT ACCEPTS `address(this)`, AND THAT IS WHAT MAKES A DEFERRED PAYLOAD WORK. A
    ///      payload that should wait rather than run carries one element targeting this
    ///      receiver's own `commit`, so the queue is filled by the payload itself rather
    ///      than by anything holding standing authority over the receiver.
    ///
    ///      It is safe for a specific reason: the only way to produce
    ///      `msg.sender == address(this)` is through `_execute`, which is reachable only
    ///      from an authenticated inbound message or a gated `execute`. A target calling
    ///      back presents itself, not this contract.
    function isAuthorizedCommitter(address account) public view returns (bool) {
        return account == address(this)
            || (account != address(0) && account == parentTransceiver)
            || isSourceTransmitter(account);
    }

    modifier onlySourceTransmitter() {
        if (!isSourceTransmitter(msg.sender)) revert NotSourceTransmitter();
        _;
    }

    modifier onlyAuthorizedCommitter() {
        if (!isAuthorizedCommitter(msg.sender)) revert NotAuthorizedCommitter();
        _;
    }

    /// @notice Bind this clone to its transmitter and pin the commitment it was created
    ///         for. Called by the transceiver at clone time; `initializer` makes it
    ///         single-shot.
    ///
    /// @dev IT TAKES THE CALLS AND RUNS THEM. IT DOES NOT SET A COMMITMENT. This is what a
    ///      bootstrap message is: stand the receiver up on a chain that has none, and
    ///      perform the payload that justified standing it up, in one step.
    ///
    /// @dev A PAYLOAD THAT SHOULD WAIT SAYS SO ITSELF, which is why the initializer needs
    ///      no second mode. To pin a hash rather than execute, the array carries one
    ///      element targeting this receiver's own `commit`: the same trick every deferred
    ///      payload uses, so nothing here has to distinguish "run now" from "approve for
    ///      later". Taking a `bytes32` here instead would need that distinction, and would
    ///      make the clone path and the ordinary path disagree about what a payload is.
    ///
    /// @dev AN EMPTY ARRAY IS THE INERT CASE, and `createReceiver` uses it to materialize a
    ///      receiver with nothing pending for the local `execute` path. It is not refused
    ///      the way `execute` refuses one: there, an empty array has no commitment and
    ///      nothing else establishes intent, whereas here the intent is to create the
    ///      receiver and the calls are the optional part.
    ///
    /// @dev THE REENTRANCY GUARD MUST BE INITIALIZED BEFORE THE CALLS RUN, once there is
    ///      one. There is not yet: `ReentrancyGuardUpgradeable` lands with the transport
    ///      rewrite, and a clone runs no constructor, so its `__ReentrancyGuard_init` has
    ///      to come above this line rather than after it.
    function initialize(address sourceTransmitter_, Call[] calldata calls)
        external
        virtual
        override
        initializer
    {
        if (sourceTransmitter_ == address(0)) revert ZeroTransmitter();

        // BEFORE the payload runs. A proxy runs no constructor of its own, so the guard is
        // uninitialized until this line, and `initialize` executes arbitrary calls.
        __ReentrancyGuard_init();

        sourceTransmitter = sourceTransmitter_;
        parentTransceiver = msg.sender;
        emit ReceiverInitialized(sourceTransmitter_, msg.sender);
        if (calls.length != 0) _execute(calls);
    }

    /// @notice Append the hash of a call array to be executed later.
    /// @dev QUEUED, NOT OVERWRITTEN. A second approval does not collide with a live one, so
    ///      a payload waiting on a slow relayer cannot stop the next from being recorded.
    ///      The same hash may be queued twice: two identical payloads are two separate
    ///      approvals and each needs its own `finalize`.
    /// @return index The queue position, stable for the life of this receiver. Keep it:
    ///         it is what `cancel` takes.
    function commit(bytes32 commitment_)
        external
        virtual
        override
        onlyAuthorizedCommitter
        returns (uint256 index)
    {
        _requireCommittable(commitment_);
        index = _commit(commitment_);
    }

    /// @notice Withdraw a queued approval so it can never be finalized.
    ///
    /// @dev THIS IS WHAT MAKES ORDERED EXECUTION SAFE. Because `finalize` insists on the
    ///      oldest outstanding entry, a payload that can never succeed would otherwise
    ///      stall everything behind it permanently. Cancelling zeroes the entry in place
    ///      and `finalize` steps over it.
    ///
    /// @dev GATED EXACTLY LIKE `commit`, AND THAT IS THE RIGHT BAR. Cancelling grants no
    ///      authority committing does not: an authorized committer can already queue any
    ///      approval, so letting it remove one it queued adds nothing. Leaving it
    ///      permissionless would instead hand any caller a way to strip approvals, which
    ///      is the one direction that would be an escalation.
    ///
    /// @dev An already-executed entry is refused rather than treated as a no-op. Reporting
    ///      success would suggest a payload had been stopped when it has already run.
    ///
    /// @dev IT NAMES THE APPROVAL TWICE, AND BOTH HAVE TO AGREE. The index says which slot
    ///      and `expected` says which approval, so a caller working from stale state
    ///      cannot withdraw a different payload than the one it meant. Indices are stable
    ///      and the guards above already catch the ordinary mistakes, so this is not
    ///      protecting against a race: it is protecting against an off-by-one being
    ///      indistinguishable from success. Cancelling the wrong approval is silent
    ///      otherwise: the queue simply loses a payload nobody chose to drop, and the
    ///      first sign of it is a `finalize` that stops matching.
    ///
    ///      It matters most for the remote path, where the call is built by
    ///      `cancellationCall` at approval time and executes later, against a queue that
    ///      may have moved in between.
    /// @param expected The commitment currently queued at `index`, from `commitmentAt`.
    function cancel(uint256 index, bytes32 expected)
        external
        virtual
        override
        onlyAuthorizedCommitter
    {
        if (index >= _commitments.length) revert IndexOutOfRange(index);
        bytes32 pending = _commitments[index];
        if (pending == bytes32(0)) revert AlreadyCancelled(index);
        if (index < _head) revert AlreadyConsumed(index);
        if (pending != expected) revert CancelMismatch(index, pending, expected);

        delete _commitments[index];
        emit ReceiverCancelled(index, pending);
    }

    /// @notice Supply the calls the OLDEST outstanding approval was made over, and run them.
    ///
    /// @dev Deliberately NOT gated on the transmitter. Anyone may supply the calls,
    ///      because only the array matching the commitment does anything: that is the
    ///      point of committing to a hash instead of trusting a caller.
    ///
    /// @dev IT TAKES THE HEAD OF THE QUEUE AND NOTHING ELSE. A caller cannot choose which
    ///      approval to discharge, so a relayer holding two valid payloads cannot decide
    ///      which lands first. Skipping one requires `cancel`, which is gated, so
    ///      reordering is an owner decision, recorded on-chain, rather than a relayer's.
    ///
    /// @dev THE COMMITMENT IT DISCHARGES MAY HAVE BEEN BUILT IN EITHER FORM. `Commitment`
    ///      hashes `Call[]` and the equivalent opaque elements to one value, so an
    ///      approval made over `bytes[]` off-chain is finalized by the typed array here.
    ///      The approval covers the calls, not the serialization somebody chose.
    function finalize(Call[] calldata calls) external virtual nonReentrant {
        _finalizeNext(calls);
    }

    /// @notice Discharge several queued approvals in one transaction, in queue order.
    ///
    /// @dev `batches[i]` must match the i-th outstanding approval: this is the same FIFO
    ///      rule applied repeatedly, not a way to pick entries out of order.
    ///
    /// @dev ALL OR NOTHING, for the same reason one array is. Each approval covers its
    ///      batch as a unit and the head pointer advances as each is consumed, so letting
    ///      a prefix stand would discharge approvals whose payloads never completed and
    ///      leave the queue advanced past them unrepeatably.
    function finalize(Call[][] calldata batches) external virtual nonReentrant {
        uint256 n = batches.length;
        if (n == 0) revert EmptyBatch();
        for (uint256 i; i < n; ++i) {
            _finalizeNext(batches[i]);
        }
    }

    /// @notice Run these calls now, with no commitment and no hash comparison.
    ///
    /// @dev IT GRANTS NO AUTHORITY THAT `commit` DOES NOT ALREADY GRANT. That is the
    ///      argument the gate rests on, and it is worth stating precisely: an authorized
    ///      committer can pin the hash of ANY array and then let anyone finalize it, so
    ///      it can already cause any array to run here. `execute` removes a round trip
    ///      and a redundant hash, not a check. Widening `isAuthorizedCommitter` would
    ///      widen both together, which is the correct coupling.
    ///
    /// @dev THE CHECK IT SKIPS IS ONE THE CALLER HAS ALREADY MADE. The commit/finalize path
    ///      exists for when the two steps are separated in TIME: a payload that arrives
    ///      now and is pushed through later, by anyone. When they happen in one
    ///      transaction there is nothing left for a commitment to protect against.
    ///
    /// @dev IT DOES NOT TOUCH A PENDING COMMITMENT. A hash pinned by `commit` stays
    ///      pinned and still requires its own `finalize`. Consuming it here would let an
    ///      unrelated array silently discharge an approval that was made over a different
    ///      one, which is the single thing the commitment is for.
    ///
    /// @dev The event is DISTINCT from `ReceiverFinalized` on purpose. An execution that
    ///      skipped the hash comparison must be distinguishable on-chain from one that
    ///      did not; a monitor that cannot tell them apart cannot audit either.
    function execute(Call[] calldata calls)
        external
        payable
        virtual
        onlyAuthorizedCommitter
        nonReentrant
    {
        if (calls.length == 0) revert EmptyExecution();
        emit ReceiverExecuted(msg.sender, calls.length);
        _execute(calls);
    }

    /* ================================= the rules =============================== */

    /// @notice The discharge rule: only the approved array does anything.
    ///
    /// @dev THE CHAIN-BINDING TRAVELS WITH THE CHECK, NOT WITH THE CALLER.
    ///      `Commitment.isHashedCall` folds in `ChainKey.local()`, so wherever this runs it
    ///      binds to the chain it runs on. Accounts sit at deterministic addresses across
    ///      chains, which is exactly where a cross-chain replay would otherwise work.
    ///
    /// @dev THE APPROVAL MAY HAVE BEEN BUILT IN EITHER FORM. `Commitment` hashes `Call[]`
    ///      and the equivalent opaque elements to one value, so a commitment computed
    ///      off-chain over `bytes[]` (the canonical, VM-agnostic form) is discharged by
    ///      the typed array supplied here. The commitment approves the calls, not the
    ///      serialization somebody chose to deliver them in.
    function _requireMatchingCalls(bytes32 pending, Call[] memory calls) private view {
        if (pending == bytes32(0)) revert NothingCommitted();
        if (!Commitment.isHashedCall(pending, calls)) revert CommitmentMismatch();
    }

    /// @notice The pinning rule: an approval is never zero.
    ///
    /// @dev ZERO IS THE SENTINEL, WHICH IS THE WHOLE RULE. It marks a cancelled queue
    ///      entry and an absent one, so accepting it as an approval would create a record
    ///      that every reader treats as not there.
    ///
    /// @dev THERE IS NO "ONE LIVE APPROVAL" RULE, because approvals are a queue: a second
    ///      commit appends rather than replacing, so there is nothing to overwrite and
    ///      nothing to protect. Refusing a duplicate would be wrong on its own terms too:
    ///      two identical payloads are two separate approvals, and each needs its own
    ///      `finalize`.
    function _requireCommittable(bytes32 incoming) private pure {
        if (incoming == bytes32(0)) revert ZeroCommitment();
    }

    /// @dev Consume the head of the queue. The head advances BEFORE `_execute` runs, so a
    ///      reentrant call sees this approval already spent and cannot discharge it twice.
    function _finalizeNext(Call[] calldata calls) private {
        uint256 index = _nextIndex();
        bytes32 pending = _commitments[index];
        _requireMatchingCalls(pending, calls);

        _head = index + 1;
        emit ReceiverFinalized(index, pending, calls.length);
        _execute(calls);
    }

    /// @dev The oldest outstanding approval, stepping over anything cancelled.
    ///      Cancelled entries are only ever skipped forwards, so the scan is bounded by
    ///      the run of cancellations at the head and the head pointer moves past them the
    ///      first time a payload is finalized.
    function _nextIndex() private view returns (uint256 index) {
        uint256 len = _commitments.length;
        for (index = _head; index < len; ++index) {
            if (_commitments[index] != bytes32(0)) return index;
        }
        revert NothingCommitted();
    }

    /* ================================== queue reads ============================= */

    /// @notice The approval `finalize` will require next, or zero when none is pending.
    function commitment() public view returns (bytes32) {
        uint256 len = _commitments.length;
        for (uint256 i = _head; i < len; ++i) {
            if (_commitments[i] != bytes32(0)) return _commitments[i];
        }
        return bytes32(0);
    }

    /// @notice The queue position `finalize` will consume next.
    /// @dev Reverts when nothing is outstanding, so a caller cannot mistake "the queue is
    ///      empty" for "position zero".
    function nextIndex() external view returns (uint256) {
        return _nextIndex();
    }

    /// @notice Every position ever committed, including spent and cancelled ones.
    function queueLength() external view returns (uint256) {
        return _commitments.length;
    }

    /// @notice The head pointer. Everything below it has been executed or skipped.
    function head() external view returns (uint256) {
        return _head;
    }

    /// @notice The approval at `index`. Zero means cancelled, or never committed.
    /// @dev A CONSUMED ENTRY KEEPS ITS VALUE, so `commitmentAt(i) != 0 && i < head()`
    ///      identifies one that executed, and `commitmentAt(i) == 0` one that was
    ///      cancelled. Deleting on finalize would collapse those two into one state.
    function commitmentAt(uint256 index) external view returns (bytes32) {
        if (index >= _commitments.length) revert IndexOutOfRange(index);
        return _commitments[index];
    }

    /// @notice How many approvals are still outstanding.
    function pendingCount() external view returns (uint256 n) {
        uint256 len = _commitments.length;
        for (uint256 i = _head; i < len; ++i) {
            if (_commitments[i] != bytes32(0)) ++n;
        }
    }


    /// @notice Split a canonical opaque element into its target, value, and calldata.
    /// @dev Use this rather than decoding by hand so every protocol agrees on the layout.
    ///      Delegates to `Calls` so the layout is defined in exactly one place.
    function _decodeCall(bytes calldata call)
        internal
        pure
        returns (address target, uint256 value, bytes memory data)
    {
        Call memory c = Calls.decode(call);
        return (c.target, c.value, c.data);
    }

    /// @notice Run a payload that arrived over the wire.
    ///
    /// @dev THE INBOUND FUNNEL. A provider adapter authenticates its origin and routes the
    ///      payload here; this decodes and executes it. Execution runs INSIDE the bridge
    ///      callback, so a reverting payload fails the message rather than stranding
    ///      anything, and every provider lets anyone re-execute a failed message, which
    ///      makes it a retry rather than a loss.
    ///
    /// @dev A PAYLOAD THAT SHOULD WAIT SAYS SO ITSELF, by carrying a self-call to `commit`.
    ///      Nothing here distinguishes the two, which is why no message-type tag exists.
    ///
    /// @dev `nonReentrant`, shared with `finalize` and `execute`. Execution calls arbitrary
    ///      targets from inside a provider callback, which is a surface a purely local
    ///      path would not have.
    function _onMessage(bytes calldata payload) internal virtual nonReentrant {
        Call[] memory calls = Payload.decodeCalls(payload);
        emit ReceiverDelivered(calls.length);
        _execute(calls);
    }

    /// @notice Accept ETH, so a receiver can be funded ahead of a `finalize` that spends it.
    /// @dev `execute` is payable and carries its own value, but `finalize` is permissionless
    ///      and takes none: a payload with value finalized by a third party has to spend a
    ///      balance that is already here.
    receive() external payable {}

    function _commit(bytes32 commitment_) internal returns (uint256 index) {
        index = _commitments.length;
        _commitments.push(commitment_);
        emit ReceiverCommitted(index, commitment_);
    }
}
