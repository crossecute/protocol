// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {Call} from "src/messaging/Call.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Executor} from "src/messaging/Executor.sol";
import {Payload} from "src/messaging/Payload.sol";
import {RolesEnumerable} from "src/messaging/Roles.sol";
import {IERC7786Recipient} from "src/messaging/IErc7786.sol";

/// @notice Two-step execution: approve a hash now, supply the matching array later.
/// @dev `commit` is gated and `finalize` is not: only an array matching an approved hash does
///      anything, so whoever relays it is irrelevant.
interface ICommitFinalize {
    function commit(bytes32 commitment) external returns (uint256 approvals);
    function finalize(Call[] calldata calls) external;
    function finalize(Call[][] calldata batches) external;
}

/// @notice Withdrawing an approval.
/// @dev Gated on a receiver by its transmitter, or a payload it is already executing.
interface ICancel {
    function cancel(bytes32 commitment) external;
}

/// @notice One-step execution: run this array, no hash comparison.
/// @dev `finalize` is permissionless because it checks the array against an approved hash;
///      `execute` skips the hash, so it is gated on the caller instead. `Call[]` only: an EVM
///      receiver runs EVM calls, and `Commitment` hashes both element forms to one value.
interface IExecute {
    function execute(Call[] calldata calls) external payable;
}

/// @notice What a transceiver needs from the receiver it creates and reuses.
interface IReceiverInit is ICommitFinalize, ICancel, IExecute {
    function initialize(address sourceTransmitter, Call[] calldata calls) external;
}

/// @title ReceiverBase
/// @notice The destination-side half. One receiver per transmitter per destination, created
///         by the transceiver and reused for every payload that transmitter sends.
///
/// @dev Approvals are an unordered map of hash to count. A map, so a pending approval never
///      blocks recording the next; a count, since two identical payloads are two approvals;
///      unordered, so an unrelayed payload stalls nothing, and a relayer holding two arrays
///      chooses their order. `cancel` takes the hash, so it cannot go stale like an index.
///
/// @dev All state is storage, set in the single-shot `initialize`: immutables would live in
///      the implementation and be shared by every account.
///
/// @dev `Commitment.hashCalls` seeds with `ChainKey.local()`, so an array approved for one
///      chain cannot be finalized on another where the same account address exists.
///
/// @dev Uses OZ 5.4's `ReentrancyGuardUpgradeable`, whose state is ERC-7201 namespaced; 5.4's
///      plain `ReentrancyGuard` would take a sequential slot. `__ReceiverBase_init` starts it
///      before any payload runs. The guard covers `_onMessage`, both `finalize` overloads, and
///      `execute` under one lock.
abstract contract ReceiverBase is
    Initializable,
    Executor,
    RolesEnumerable,
    ReentrancyGuardUpgradeable,
    IReceiverInit,
    IERC7786Recipient
{
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;

    /// @notice The outstanding approvals: commitment => how many times it may still be
    ///         finalized.
    /// @dev Enumerable, so what is outstanding can be read on-chain. Each `finalize`
    ///      decrements, and the entry leaves the map at zero.
    EnumerableMap.Bytes32ToUintMap private _commitments;

    /// The transmitter this receiver answers to. Set once, at initialization.
    address public sourceTransmitter;
    /// The transceiver that created this receiver. Not `transceiver`, which on
    /// `TransmitterBase` means the other direction.
    address public parentTransceiver;

    event ReceiverInitialized(address indexed sourceTransmitter, address indexed transceiver);
    event ReceiverExecuted(address indexed caller, uint256 callCount);
    event Committed(bytes32 indexed commitment, uint256 outstanding);
    event Finalized(bytes32 indexed commitment, uint256 remaining, uint256 callCount);
    /// @dev A payload that ran on arrival, as distinct from one a commitment discharged or a
    ///      gated entry point drove locally.
    event Delivered(uint256 callCount);
    /// @dev Carries what was dropped, since cancelling removes every outstanding copy.
    event Cancelled(bytes32 indexed commitment, uint256 dropped);

    error NotSourceTransmitter();
    error ZeroTransmitter();
    /// @dev The message names a sender other than this receiver's transmitter: another
    ///      account's payload at the wrong receiver.
    error SenderIsNotThisAccount(bytes sender);
    /// @dev No approval matches the array supplied.
    error CommitmentMismatch();
    /// @dev Nothing outstanding under that hash. Refused rather than a no-op, since success
    ///      would suggest a payload was stopped that may already have run.
    error NotCommitted(bytes32 commitment);
    /// @dev Zero would make "committed" indistinguishable from "never committed".
    error ZeroCommitment();
    error EmptyBatch();
    /// @dev The sender envelope's address half is not 20 bytes, so it cannot be an EVM
    ///      transmitter.
    error UnauthenticatedSender(bytes sender);

    /// @notice Whether `account` is the transmitter this receiver was created for.
    function isSourceTransmitter(address account) public view returns (bool) {
        return account != address(0) && account == sourceTransmitter;
    }

    /// @notice Who may drive this receiver: its transmitter, and a payload it is executing.
    ///
    /// @dev Not the transceiver: after initialization it has no authority here, so one
    ///      compromised transceiver cannot drive every account it created.
    ///
    /// @dev `address(this)` lets a deferred payload call this receiver's own `commit`. Only
    ///      `_execute` can produce it, reachable from an authenticated inbound message or a
    ///      gated entry point. Stated explicitly because receiver and transmitter addresses
    ///      differ on zkSync and Tron.
    function isAuthorizedCaller(address account) public view returns (bool) {
        return account == address(this) || isSourceTransmitter(account);
    }

    modifier onlySourceTransmitter() {
        if (!isAuthorizedCaller(msg.sender)) revert NotSourceTransmitter();
        _;
    }

    /* ================================ initializing ============================== */

    /// @notice Bind this account to its transmitter and run the payload it was created for.
    /// @dev For a binding that needs no setup of its own; one that does declares its own
    ///      `initialize` and calls `__ReceiverBase_init` last.
    function initialize(address sourceTransmitter_, Call[] calldata calls) external virtual override initializer {
        __ReceiverBase_init(sourceTransmitter_, calls);
    }

    /// @notice The work behind `initialize`: bind, then run the bootstrap calls.
    ///
    /// @dev Runs the calls rather than recording a commitment; a payload that should wait
    ///      carries a self-call to `commit`. An empty array is allowed here, unlike in
    ///      `execute`, since creating the receiver is the intent.
    ///
    /// @dev Separate so a binding can configure its provider before the payload runs, from
    ///      inside its own `initializer` and ahead of this call; `super.initialize` would run the
    ///      payload first. The transceiver's reach into a receiver ends here.
    function __ReceiverBase_init(address sourceTransmitter_, Call[] calldata calls) internal onlyInitializing {
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
    /// @dev The only membership change after initialization anywhere, and it only subtracts:
    ///      `grantRole` is `onlyInitializing`, and `CrossProxy` arms once, so a dropped
    ///      transport is never replaced. A gateway that can deliver can forge, so going deaf is
    ///      the recoverable failure.
    ///
    /// @dev A transceiver has no equivalent: it is shared by every owner on its chain.
    function revokeGateway(address gateway) external onlySourceTransmitter {
        _revokeRole(GATEWAY_ROLE, gateway);
    }

    /* ================================== approving =============================== */

    /// @notice Approve the hash of a call array, to be executed later by anyone.
    /// @dev The same hash may be approved twice; each approval needs its own `finalize`.
    /// @return approvals How many times this hash may now be finalized.
    function commit(bytes32 commitment_) external override onlySourceTransmitter returns (uint256 approvals) {
        if (commitment_ == bytes32(0)) revert ZeroCommitment();

        (, uint256 held) = _commitments.tryGet(commitment_);
        approvals = held + 1;
        _commitments.set(commitment_, approvals);
        emit Committed(commitment_, approvals);
    }

    /// @notice Withdraw an approval so it can never be finalized.
    /// @dev Gated like `commit`, which already lets the caller approve any array. Drops every
    ///      copy: a wrong payload is wrong in every copy, and re-approving is one `commit`
    ///      away. An absent approval reverts, since success would suggest a payload was stopped
    ///      that may have run.
    function cancel(bytes32 commitment_) external virtual override onlySourceTransmitter {
        (bool held, uint256 dropped) = _commitments.tryGet(commitment_);
        if (!held) revert NotCommitted(commitment_);

        _commitments.remove(commitment_);
        emit Cancelled(commitment_, dropped);
    }

    /* ================================= finalizing =============================== */

    /// @notice Supply an approved array, and run it.
    ///
    /// @dev Ungated: only an array matching an outstanding commitment does anything, which lets
    ///      a third party pay the gas. It discharges the approval the array hashes to.
    ///
    /// @dev `Commitment` hashes `Call[]` and the equivalent opaque elements to one value, so an
    ///      approval made over `bytes[]` is discharged by the typed array.
    function finalize(Call[] calldata calls) external override nonReentrant {
        _finalize(calls);
    }

    /// @notice Discharge several approvals in one transaction, in the order given.
    /// @dev All or nothing, since each entry is decremented before its payload runs.
    function finalize(Call[][] calldata batches) external override nonReentrant {
        uint256 n = batches.length;
        if (n == 0) revert EmptyBatch();
        for (uint256 i; i < n; ++i) {
            _finalize(batches[i]);
        }
    }

    /// @dev `Commitment.hashCalls` seeds with `ChainKey.local()`, so an array approved for
    ///      another chain hashes to a value this map does not hold. The decrement happens
    ///      before `_execute`, so a re-entrant `finalize` of the same array finds it spent.
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

        emit Finalized(pending, remaining, calls.length);
        _execute(calls);
    }

    /// @notice Run these calls now, with no commitment and no hash comparison.
    ///
    /// @dev Grants nothing `commit` does not: the transmitter can already approve any array
    ///      and let anyone finalize it. `commit`, `cancel`, and `execute` share one gate.
    ///
    /// @dev Leaves pending commitments alone; each still needs its own `finalize`.
    function execute(Call[] calldata calls) external payable virtual onlySourceTransmitter nonReentrant {
        if (calls.length == 0) revert EmptyExecution();
        emit ReceiverExecuted(msg.sender, calls.length);
        _execute(calls);
    }

    /* ============================== approval reads ============================== */

    /// @notice How many times `commitment_` may still be finalized. Zero means never.
    function outstanding(bytes32 commitment_) public view returns (uint256) {
        (, uint256 held) = _commitments.tryGet(commitment_);
        return held;
    }

    /// @notice Whether `commitment_` has an approval left.
    function isCommitted(bytes32 commitment_) public view returns (bool) {
        return _commitments.contains(commitment_);
    }

    /// @notice Every outstanding approval.
    /// @dev The order is not stable: discharging one swaps the last entry into its place.
    function commitments() external view returns (bytes32[] memory hashes) {
        uint256 n = _commitments.length();
        hashes = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            (hashes[i],) = _commitments.at(i);
        }
    }

    /// @notice How many distinct approvals are outstanding: a hash approved twice counts once
    ///         here and twice in `outstanding`.
    function pendingCount() external view returns (uint256) {
        return _commitments.length();
    }

    /* ================================== delivery ================================ */

    /// @notice ERC-7786 delivery: the gateway hands over an authenticated message.
    ///
    /// @dev Two checks, both required on an `external` entry point: the gateway role says the
    ///      transport is trusted, and the sender must be this receiver's own transmitter, so a
    ///      shared gateway cannot land one account's payload in another's receiver. Compared
    ///      against the stored `sourceTransmitter`, not `address(this)`, mirroring
    ///      `TransmitterBase._requireOwnRecipient`.
    ///
    /// @dev `receiveId` is ignored: nothing here correlates messages, and replay is the
    ///      transport's to prevent (`docs/provider-spec.md` R3.5).
    function receiveMessage(bytes32, bytes calldata sender, bytes calldata payload)
        external
        payable
        override
        onlyRole(GATEWAY_ROLE)
        returns (bytes4)
    {
        Erc7930.Interop memory io = Erc7930.parseStrict(sender);
        if (io.addr.length != 20) revert UnauthenticatedSender(sender);
        // forge-lint: disable-next-line(unsafe-typecast) length checked above
        if (address(bytes20(io.addr)) != sourceTransmitter) revert SenderIsNotThisAccount(sender);

        _onMessage(payload);
        return IERC7786Recipient.receiveMessage.selector;
    }

    /// @notice Deliver `payload` if `sender`, as the provider reported it, is this receiver's
    ///         transmitter.
    /// @dev For bindings whose provider reports the sender as a plain address rather than an
    ///      ERC-7930 envelope in calldata.
    function _onMessageFrom(address sender, bytes calldata payload) internal {
        if (!isSourceTransmitter(sender)) revert NotSourceTransmitter();
        _onMessage(payload);
    }

    /// @notice Run a payload that arrived over the wire.
    ///
    /// @dev Decoded here, not by the binding. It runs inside the delivery callback, so a
    ///      reverting payload fails the message, which every provider lets anyone re-execute.
    ///      A payload that should wait carries a self-call to `commit`; nothing on the wire
    ///      distinguishes it.
    ///
    /// @dev `nonReentrant`, shared with `finalize`, since it calls arbitrary targets from a
    ///      provider callback.
    function _onMessage(bytes calldata payload) internal nonReentrant {
        Call[] memory calls = Payload.decodeCalls(payload);
        emit Delivered(calls.length);
        _execute(calls);
    }

    /// @notice Accept ETH, so a receiver can be funded ahead of a `finalize` that spends it.
    /// @dev `finalize` is permissionless and carries no value, so a payload with value
    ///      finalized by a third party spends this balance. The address is known before the
    ///      receiver exists, so a shortfall is fixed by topping up and retrying.
    receive() external payable {}
}
