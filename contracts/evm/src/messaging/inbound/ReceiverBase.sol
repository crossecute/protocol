// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Call, Calls} from "src/messaging/Call.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Executor} from "src/messaging/Executor.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Roles} from "src/messaging/Roles.sol";
import {IERC7786Recipient} from "src/messaging/IErc7786.sol";

/// @notice Two-step execution: pin a hash now, supply the matching array later.
///
/// @dev `commit` is gated and `finalize` is not, and that is the whole point: the approval
///      lives in the hash, so the only array that does anything is the one already approved
///      and whoever relays it is irrelevant.
///
/// @dev IT TAKES `Call[]`, AND ONLY `Call[]`. An EVM receiver executes EVM calls, so an
///      opaque overload would accept elements it could only decode into this shape anyway.
///      The commitment stays defined over opaque elements, because that layer must be
///      VM-agnostic and `Commitment` hashes both forms to one value; the ENTRY POINT does
///      not, because this contract only ever runs on an EVM chain.
interface ICommitFinalize {
    function commit(bytes32 commitment) external returns (uint256 approvals);
    function cancel(bytes32 commitment) external;
    function finalize(Call[] calldata calls) external;
    function finalize(Call[][] calldata batches) external;
}

/// @notice One-step execution: run this array, no hash comparison.
/// @dev THE MIRROR OF `ICommitFinalize`, and the trade is exact. `finalize` may be
///      permissionless BECAUSE it checks the payload against an approved hash; `execute`
///      skips that check, so it is gated on the caller instead. Exactly one of the two
///      constraints has to hold, and each interface picks a different one.
interface IExecute {
    function execute(Call[] calldata calls) external payable;
}

/// @notice What a transceiver needs from the receiver it creates and reuses.
interface IReceiverInit is ICommitFinalize, IExecute {
    function initialize(address sourceTransmitter, Call[] calldata calls) external;
}

/// @title ReceiverBase
/// @notice The destination-side half. Exactly ONE receiver per transmitter per destination,
///         created by the transceiver and reused for every payload that transmitter sends.
///
/// @dev APPROVALS ARE AN ORDERED, APPEND-ONLY QUEUE, and every property below follows from
///      the receiver being long-lived:
///
///      A QUEUE rather than a slot, because with one slot a second commit would have to
///      revert while one was still pending, so a payload waiting on a slow relayer would
///      block every later one from even being recorded.
///
///      APPEND-ONLY, so the index `commit` returns names that approval for the life of the
///      receiver, which is what lets `cancel` take an index and not race anything. A
///      cancelled entry is zeroed in place; a consumed one keeps its value and is passed by
///      the head pointer, so the two stay distinguishable on-chain afterwards.
///
///      STRICTLY FIFO, because a multisig payload sequence usually means something only in
///      order (approve then transfer, set then use), and a queue that executed out of order
///      would let a relayer choose which half of that pair lands first. The cost is
///      head-of-line blocking, and `cancel` is the escape hatch: ordering is only safe
///      because a stuck entry can be removed, and cancellation is only necessary because
///      execution is ordered. Neither should be removed without the other.
///
/// @dev EVERYTHING IS STORAGE, NOT IMMUTABLE. A receiver is a proxy, and immutables live in
///      the implementation's bytecode, so every account would share one value. They are set
///      in `initialize`, which the `initializer` modifier makes single-shot.
///
/// @dev THE COMMITMENT IS CHAIN-BOUND. `Commitment.hashCalls` folds `ChainKey.local()` in as
///      the seed, so an array approved for one chain cannot be finalized here. Accounts sit
///      at deterministic addresses across chains, which is exactly where a cross-chain
///      replay would otherwise work.
///
/// @dev THE REENTRANCY GUARD IS THE UPGRADEABLE ONE, WHICH AT OZ 5.4 IS NOT THE SAME
///      CONTRACT. The plain `ReentrancyGuard` keeps `_status` in a LINEAR slot at this
///      version, so mixing it into a proxied implementation would put protocol state in a
///      slot the layout has to reserve forever. The upgradeable variant keeps the same state
///      in an ERC-7201 namespaced slot, which is why it moves no field of ours. (OZ 5.5 later
///      made the plain one namespaced too and dropped the upgradeable variant; on 5.4 the
///      distinction is real and this is the side to be on.) `__ReentrancyGuard_init` runs
///      first in `__ReceiverBase_init`, before any payload can execute.
abstract contract ReceiverBase is
    Initializable,
    Executor,
    Roles,
    ReentrancyGuardUpgradeable,
    IReceiverInit,
    IERC7786Recipient
{
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;

    /// The transmitter this receiver answers to. Set once, at initialization.
    address public sourceTransmitter;
    /// The transceiver that created this receiver. Named to avoid colliding with
    /// `TransmitterBase.transceiver`, which means the opposite direction: a Transceiver
    /// inherits both.
    address public parentTransceiver;
    /// @notice The outstanding approvals: commitment => how many times it may still be
    ///         finalized.
    ///
    /// @dev A MAP RATHER THAN A QUEUE, WHICH IS WHAT MAKES EXECUTION UNORDERED. Approvals no
    ///      longer have positions, so `finalize` takes whichever array it is handed and
    ///      discharges THAT approval: a payload waiting on a slow relayer no longer blocks
    ///      every payload approved after it, and `cancel` is no longer the only way out of a
    ///      head-of-line stall. What it gives up is the guarantee that approvals land in the
    ///      order they were made — a relayer holding two valid arrays now chooses. An owner
    ///      who needs one to precede another has to express that inside the payloads.
    ///
    /// @dev THE VALUE IS A COUNT, BECAUSE A HASH IS NOT AN IDENTITY. Two identical payloads
    ///      are two separate approvals, and a set would silently collapse them into one:
    ///      approving the same transfer twice would buy one. Each `finalize` decrements, and
    ///      the entry leaves the map at zero.
    ///
    /// @dev ENUMERABLE BECAUSE "WHAT IS OUTSTANDING" HAS TO BE ANSWERABLE ON-CHAIN, and with
    ///      no ordering there is no head to read instead. `commitments()` returns the whole
    ///      set, which is what an owner reviewing what they have approved actually wants.
    EnumerableMap.Bytes32ToUintMap private _commitments;

    event ReceiverInitialized(address indexed sourceTransmitter, address indexed transceiver);
    event ReceiverCommitted(bytes32 indexed commitment, uint256 outstanding);
    /// @dev Carries what was dropped, since cancelling removes every outstanding copy.
    event ReceiverCancelled(bytes32 indexed commitment, uint256 dropped);
    event ReceiverFinalized(bytes32 indexed commitment, uint256 remaining, uint256 callCount);
    event ReceiverExecuted(address indexed caller, uint256 callCount);
    /// @dev A payload that arrived over the wire and ran on arrival, as distinct from one a
    ///      commitment discharged or the owner drove locally. A monitor that cannot tell
    ///      those apart cannot audit any of them.
    event ReceiverDelivered(uint256 callCount);

    /// @dev No approval matches the array supplied, which covers both "nothing is
    ///      outstanding" and "something is, but not this".
    error CommitmentMismatch();
    /// @dev Zero marks a cancelled queue entry and an absent one alike, so it can never be
    ///      an approval.
    error ZeroCommitment();

    error NotSourceTransmitter();
    error ZeroTransmitter();
    /// @dev The message claims to come from an address that is not this receiver's
    ///      transmitter, so it is another account's payload arriving at the wrong receiver.
    error SenderIsNotThisAccount(bytes sender);
    /// @dev Nothing outstanding under that hash, so there is nothing to withdraw. Refused
    ///      rather than treated as a no-op, because reporting success would suggest a payload
    ///      had been stopped when it may already have run.
    error NotCommitted(bytes32 commitment);
    error EmptyBatch();

    /// @notice Whether `account` is the transmitter this receiver was created for.
    function isSourceTransmitter(address account) public view returns (bool) {
        return account != address(0) && account == sourceTransmitter;
    }

    /// @notice Who may drive this receiver: its transmitter, and the payload itself.
    ///
    /// @dev THE TRANSCEIVER IS NOT ON THIS LIST, AND ITS ABSENCE IS THE POINT. It created
    ///      this receiver and initialized it, and that is the whole of its relationship:
    ///      `__ReceiverBase_init` runs the bootstrap payload on its authority, once, and
    ///      there is no way back in afterwards. Letting it `commit` would make it a STANDING
    ///      authority over every receiver it had ever created, on the chain where it is also
    ///      the contract that authenticates every inbound message: one compromise, every
    ///      account.
    ///
    /// @dev `address(this)` IS WHAT MAKES A DEFERRED PAYLOAD WORK, and it is not a second
    ///      authority: a payload that should wait carries one element targeting this
    ///      receiver's own `commit`, so the queue is filled by the approved payload itself.
    ///      It is safe because the only way to produce `msg.sender == address(this)` is
    ///      through `_execute`, reachable only from an authenticated inbound message or a
    ///      gated entry point; a target calling back presents itself, not this contract.
    ///
    ///      It is STATED rather than inherited from the address coincidence. A receiver and
    ///      its transmitter share one address wherever Ethereum's CREATE2 formula holds, so
    ///      this arm looks redundant there. It is not on zkSync or Tron, whose formulas
    ///      differ: without it, deferring would work on most of the deployment and fail
    ///      silently on the rest, which is the worst shape a bug of this kind can take.
    function isAuthorizedCaller(address account) public view returns (bool) {
        return account == address(this) || isSourceTransmitter(account);
    }

    modifier onlySourceTransmitter() {
        if (!isAuthorizedCaller(msg.sender)) revert NotSourceTransmitter();
        _;
    }

    /// @notice Bind this account to its transmitter and run the payload it was created for.
    /// @dev The default entry point, for a protocol binding that needs nothing of its own at
    ///      creation. One that does declares its own and sequences its setup ahead of the
    ///      internal initializer; see below for why the split is the only shape that works.
    function initialize(address sourceTransmitter_, Call[] calldata calls)
        external
        virtual
        override
        initializer
    {
        __ReceiverBase_init(sourceTransmitter_, calls);
    }

    /// @notice The work behind `initialize`.
    ///
    /// @dev IT TAKES THE CALLS AND RUNS THEM. IT DOES NOT SET A COMMITMENT. That is what a
    ///      bootstrap message is: stand the receiver up on a chain that has none, and perform
    ///      the payload that justified standing it up, in one step. A payload that should
    ///      wait says so itself, by carrying one element targeting this receiver's own
    ///      `commit`, so nothing here has to distinguish "run now" from "approve for later".
    ///      An empty array is the inert case and is not refused the way `execute` refuses
    ///      one: there nothing else establishes intent, whereas here the intent is to create
    ///      the receiver and the calls are the optional part.
    ///
    /// @dev SPLIT OUT SO A PROTOCOL BINDING CAN GET IN FRONT OF THE PAYLOAD, and it is the
    ///      only arrangement that compiles. A binding needs its provider configured after the
    ///      reentrancy guard and before `_execute`, and with the work inside an `external
    ///      initializer` there is no way to say that: `super.initialize` first runs the
    ///      payload against an unconfigured provider; configuring first reverts, because the
    ///      SDK's `onlyInitializing` setup would run while `_initializing` is false; and
    ///      `initializer` on both reverts `InvalidInitialization`. So a binding calls this
    ///      LAST, and never `super.initialize`.
    ///
    /// @dev THIS IS THE TRANSCEIVER'S ONLY REACH INTO A RECEIVER, AND IT ENDS HERE.
    function __ReceiverBase_init(address sourceTransmitter_, Call[] calldata calls)
        internal
        onlyInitializing
    {
        if (sourceTransmitter_ == address(0)) revert ZeroTransmitter();

        // First, so the guard is live before the payload at the end of this function runs.
        __ReentrancyGuard_init();

        sourceTransmitter = sourceTransmitter_;
        parentTransceiver = msg.sender;
        emit ReceiverInitialized(sourceTransmitter_, msg.sender);
        if (calls.length != 0) _execute(calls);
    }

    /// @notice Stop trusting a transport this receiver was armed with.
    ///
    /// @dev THE ONE MEMBERSHIP CHANGE THAT SURVIVES INITIALIZATION, ANYWHERE IN THE PROTOCOL,
    ///      and it only ever subtracts. There is no matching grant: `grantRole` is
    ///      `onlyInitializing`, so a transport dropped here cannot be replaced and the account
    ///      is deaf until it is redeployed — which it cannot be, since `CrossProxy` arms once.
    ///      That is the honest cost, and it is the right side to fail on: a gateway that can
    ///      deliver can forge, so the recoverable case is "this account stops accepting
    ///      messages" and the unrecoverable one is "a compromised transport keeps driving it".
    ///
    /// @dev GATED LIKE `commit` AND `cancel`, WHICH IS THE STRONGEST BAR AVAILABLE HERE. Only
    ///      the source transmitter reaches it, meaning the owner acting through their own
    ///      account on the home chain, or a payload this receiver is already executing. The
    ///      transceiver that created this receiver is NOT on that list, as everywhere else:
    ///      its whole relationship with a receiver is the initializer it already spent.
    ///
    /// @dev A SPOKE TRANSCEIVER HAS NO EQUIVALENT, deliberately. It is shared by every owner
    ///      on that chain, so dropping its gateway would take every account's bootstrap path
    ///      with it, on the authority of whoever reached the entry point. Its transports are
    ///      whatever its `Deployment` named, for life; only accounts, which are one owner's
    ///      each, can drop theirs.
    function revokeGateway(address gateway) external onlySourceTransmitter {
        _revokeRole(GATEWAY_ROLE, gateway);
    }

    /// @notice Approve the hash of a call array, to be executed later by anyone.
    /// @dev The same hash may be approved twice: two identical payloads are two separate
    ///      approvals, and each needs its own `finalize`. That is what the count is for.
    /// @return approvals How many times this hash may now be finalized.
    function commit(bytes32 commitment_)
        external
        virtual
        override
        onlySourceTransmitter
        returns (uint256 approvals)
    {
        _requireCommittable(commitment_);

        (, uint256 held) = _commitments.tryGet(commitment_);
        approvals = held + 1;
        _commitments.set(commitment_, approvals);
        emit ReceiverCommitted(commitment_, approvals);
    }

    /// @notice Withdraw an approval so it can never be finalized.
    ///
    /// @dev GATED EXACTLY LIKE `commit`, AND THAT IS THE RIGHT BAR. Cancelling grants no
    ///      authority committing does not: an authorized caller can already approve any
    ///      array, so letting it remove one adds nothing, while leaving it permissionless
    ///      would hand any caller a way to strip approvals.
    ///
    /// @dev IT NAMES THE APPROVAL ITSELF, WHICH IS THE ONLY HANDLE THERE IS NOW. Positions
    ///      are gone with the queue, and a hash cannot go stale the way an index could: the
    ///      value a caller passes is the value that is removed, so cancelling the wrong
    ///      approval requires naming the wrong approval. An absent one reverts rather than
    ///      passing silently, because reporting success would suggest a payload had been
    ///      stopped when it may already have run.
    ///
    /// @dev IT ZEROES THE ENTRY, NOT ONE COPY OF IT. A hash approved three times is dropped
    ///      three times over, because cancelling is what an owner reaches for when a payload
    ///      turns out to be wrong, and a payload that is wrong is wrong in every copy.
    ///      Re-approving is one `commit` away if only some were meant to go.
    function cancel(bytes32 commitment_) external virtual override onlySourceTransmitter {
        (bool held, uint256 dropped) = _commitments.tryGet(commitment_);
        if (!held) revert NotCommitted(commitment_);

        _commitments.remove(commitment_);
        emit ReceiverCancelled(commitment_, dropped);
    }

    /// @notice Supply an approved array, and run it.
    ///
    /// @dev NOT GATED ON THE TRANSMITTER, deliberately: only an array matching an outstanding
    ///      commitment does anything, which is the point of approving a hash instead of
    ///      trusting a caller.
    ///
    /// @dev IT DISCHARGES THE APPROVAL THE ARRAY MATCHES, NOT THE OLDEST ONE. The array names
    ///      its own approval by hashing to it, so nothing has to be in order and nothing can
    ///      block: a payload nobody relays sits outstanding without stalling the ones approved
    ///      after it. The cost is that a relayer holding two valid arrays chooses which lands
    ///      first, so an owner needing a sequence expresses it inside the payloads.
    ///
    /// @dev THE COMMITMENT MAY HAVE BEEN BUILT IN EITHER FORM. `Commitment` hashes `Call[]`
    ///      and the equivalent opaque elements to one value, so an approval made over
    ///      `bytes[]` off-chain is discharged by the typed array here. The approval covers
    ///      the calls, not the serialization somebody chose.
    function finalize(Call[] calldata calls) external virtual nonReentrant {
        _finalize(calls);
    }

    /// @notice Discharge several approvals in one transaction, in the order given.
    ///
    /// @dev ALL OR NOTHING, because each entry is decremented before its payload runs: a
    ///      prefix standing would discharge approvals whose payloads never completed.
    function finalize(Call[][] calldata batches) external virtual nonReentrant {
        uint256 n = batches.length;
        if (n == 0) revert EmptyBatch();
        for (uint256 i; i < n; ++i) {
            _finalize(batches[i]);
        }
    }

    /// @notice Run these calls now, with no commitment and no hash comparison.
    ///
    /// @dev IT GRANTS NO AUTHORITY `commit` DOES NOT ALREADY GRANT, which is the argument the
    ///      gate rests on: the transmitter can pin the hash of ANY array and let anyone
    ///      finalize it, so it can already cause any array to run here. This removes a round
    ///      trip and a redundant hash, not a check. The check it skips is one the caller has
    ///      already made, because commit/finalize exists for when the two steps are separated
    ///      in TIME; in one transaction there is nothing left for a commitment to protect.
    ///      All three entry points therefore share ONE gate, so widening it is a single
    ///      decision rather than three that could disagree.
    ///
    /// @dev IT DOES NOT TOUCH A PENDING COMMITMENT. A hash pinned by `commit` stays pinned
    ///      and still requires its own `finalize`. Consuming it here would let an unrelated
    ///      array silently discharge an approval made over a different one.
    function execute(Call[] calldata calls)
        external
        payable
        virtual
        onlySourceTransmitter
        nonReentrant
    {
        if (calls.length == 0) revert EmptyExecution();
        emit ReceiverExecuted(msg.sender, calls.length);
        _execute(calls);
    }

    /* ================================= the rules =============================== */

    /// @notice The discharge rule: only an approved array does anything.
    /// @dev `Commitment.hashCalls` folds in `ChainKey.local()`, so the chain-binding travels
    ///      with the check rather than with the caller: wherever this runs, it binds to the
    ///      chain it runs on, and an array approved for another chain hashes to a value this
    ///      map does not hold.
    ///
    /// @dev IT DECREMENTS BEFORE `_execute` RUNS, so a re-entrant `finalize` supplying the
    ///      same array finds that copy of the approval already spent.
    function _finalize(Call[] calldata calls) private {
        bytes32 pending = Commitment.hashCalls(calls);

        (bool held, uint256 approvals) = _commitments.tryGet(pending);
        if (!held) revert CommitmentMismatch();

        uint256 remaining = approvals - 1;
        if (remaining == 0) {
            _commitments.remove(pending);
        } else {
            _commitments.set(pending, remaining);
        }

        emit ReceiverFinalized(pending, remaining, calls.length);
        _execute(calls);
    }

    /// @notice The pinning rule: an approval is never zero, because zero is what an absent
    ///         entry hashes to nowhere and would make "committed" indistinguishable from
    ///         "never committed" for a caller reading the map.
    function _requireCommittable(bytes32 incoming) private pure {
        if (incoming == bytes32(0)) revert ZeroCommitment();
    }

    /* ============================== approval reads ============================== */

    /// @notice How many times `commitment_` may still be finalized. Zero means never.
    function outstanding(bytes32 commitment_) external view returns (uint256) {
        (, uint256 held) = _commitments.tryGet(commitment_);
        return held;
    }

    /// @notice Whether `commitment_` has an approval left.
    function isCommitted(bytes32 commitment_) external view returns (bool) {
        return _commitments.contains(commitment_);
    }

    /// @notice Every outstanding approval, which is what an owner reviewing what they have
    ///         approved actually wants.
    /// @dev THE ORDER IS NOT STABLE AND MEANS NOTHING. Discharging one swaps the last entry
    ///      into its place, and nothing executes by position anyway.
    function commitments() external view returns (bytes32[] memory hashes) {
        uint256 n = _commitments.length();
        hashes = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            (hashes[i],) = _commitments.at(i);
        }
    }

    /// @notice How many distinct approvals are outstanding.
    /// @dev DISTINCT, not total: a hash approved twice counts once here and twice in
    ///      `outstanding`.
    function pendingCount() external view returns (uint256) {
        return _commitments.length();
    }

    /* ================================== inbound ================================= */

    /// @notice Split a canonical opaque element into its target, value, and calldata.
    /// @dev Delegates to `Calls` so the layout is defined in exactly one place.
    function _decodeCall(bytes calldata call)
        internal
        pure
        returns (address target, uint256 value, bytes memory data)
    {
        Call memory c = Calls.decode(call);
        return (c.target, c.value, c.data);
    }

    /// @notice ERC-7786 delivery: the gateway hands over an authenticated message.
    ///
    /// @dev THE TWO CHECKS ARE NOT THE SAME CHECK, AND BOTH ARE REQUIRED. This is `external`,
    ///      so without them anyone could hand this receiver a payload and have it executed.
    ///      The gateway check says the message came through transport this account trusts;
    ///      the sender check says it came from THIS ACCOUNT on the other side. An honest but
    ///      shared gateway would otherwise let one account's payload land in another's
    ///      receiver.
    ///
    /// @dev THE SENDER CHECK COMPARES AGAINST `sourceTransmitter`, NOT `address(this)`, and
    ///      that is the mirror of what `TransmitterBase._requireOwnRecipient` does with its
    ///      recorded counterpart. The two happen to be equal wherever Ethereum's CREATE2
    ///      formula holds, which is what made `address(this)` look free; they are NOT equal
    ///      on zkSync or Tron, where the receiver and its transmitter part company, and
    ///      comparing against the derived value there refused the only transmitter that
    ///      could legitimately send. The stored fact holds on every chain.
    ///
    /// @dev IT STILL NEEDS NO CONFIGURATION. `sourceTransmitter` is written once by the
    ///      transceiver at creation, from the `(owner, salt)` pair the bootstrap message
    ///      carried, and there is no setter: there is no state an operator could set wrongly
    ///      after the fact.
    ///
    /// @dev THE `receiveId` IS DELIBERATELY IGNORED. ERC-7786 offers it for correlation, and
    ///      this protocol needs none: a payload either matches a queued commitment or
    ///      executes on arrival, and neither asks which message carried it. Replay is the
    ///      transport's to prevent; see the provider spec.
    function receiveMessage(bytes32, bytes calldata sender, bytes calldata payload)
        external
        payable
        virtual
        override
        onlyRole(GATEWAY_ROLE)
        returns (bytes4)
    {
        Erc7930.Interop memory io = Erc7930.parseStrict(sender);
        if (io.addr.length != 20 || address(bytes20(io.addr)) != sourceTransmitter) {
            revert SenderIsNotThisAccount(sender);
        }

        _onMessage(payload);
        return IERC7786Recipient.receiveMessage.selector;
    }

    /// @notice Run a payload that arrived over the wire.
    ///
    /// @dev THE INBOUND FUNNEL, and the binding does not decode: every provider gets the same
    ///      decoder and the same failure mode. Execution runs INSIDE the delivery callback,
    ///      so a reverting payload fails the message rather than stranding anything, and
    ///      every provider lets anyone re-execute a failed message, which makes it a retry
    ///      rather than a loss.
    ///
    /// @dev `nonReentrant`, shared with `finalize` and `execute`. Execution calls arbitrary
    ///      targets from inside a provider callback, which is a surface a purely local path
    ///      would not have.
    function _onMessage(bytes calldata payload) internal virtual nonReentrant {
        Call[] memory calls = Payload.decodeCalls(payload);
        emit ReceiverDelivered(calls.length);
        _execute(calls);
    }

    /// @notice Accept ETH, so a receiver can be funded ahead of a `finalize` that spends it.
    /// @dev `execute` is payable and carries its own value, but `finalize` is permissionless
    ///      and takes none: a payload with value finalized by a third party has to spend a
    ///      balance that is already here. The address is deterministic and fundable before
    ///      the receiver exists, which makes a shortfall "top it up and retry".
    receive() external payable {}

}
