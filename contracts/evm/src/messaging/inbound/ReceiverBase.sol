// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Call, Calls} from "src/messaging/Call.sol";
import {ICancel, ICommitFinalize, InboundBase} from "src/messaging/inbound/InboundBase.sol";

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
///      before any payload runs.
abstract contract ReceiverBase is Initializable, InboundBase, IReceiverInit {
    /// The transmitter this receiver answers to. Set once, at initialization.
    address public sourceTransmitter;
    /// The transceiver that created this receiver. Not `transceiver`, which on
    /// `TransmitterBase` means the other direction.
    address public parentTransceiver;
    event ReceiverInitialized(address indexed sourceTransmitter, address indexed transceiver);
    event ReceiverCommitted(bytes32 indexed commitment, uint256 outstanding);
    /// @dev Carries what was dropped, since cancelling removes every outstanding copy.
    event ReceiverCancelled(bytes32 indexed commitment, uint256 dropped);
    event ReceiverFinalized(bytes32 indexed commitment, uint256 remaining, uint256 callCount);
    event ReceiverExecuted(address indexed caller, uint256 callCount);
    error NotSourceTransmitter();
    error ZeroTransmitter();
    /// @dev The message names a sender other than this receiver's transmitter: another
    ///      account's payload at the wrong receiver.
    error SenderIsNotThisAccount(bytes sender);

    /// @notice Whether `account` is the transmitter this receiver was created for.
    function isSourceTransmitter(address account) public view returns (bool) {
        return account != address(0) && account == sourceTransmitter;
    }

    /// @notice Deliver `payload` if `sender`, as the provider reported it, is this receiver's
    ///         transmitter.
    /// @dev For bindings whose provider reports the sender as a plain address rather than an
    ///      ERC-7930 envelope in calldata.
    function _onMessageFrom(address sender, bytes calldata payload) internal {
        if (!isSourceTransmitter(sender)) revert NotSourceTransmitter();
        _onMessage(payload);
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
    /// @dev Separate so a binding can configure its provider after the reentrancy guard and
    ///      before the payload runs, from inside its own `initializer`; `super.initialize`
    ///      would run the payload first. The transceiver's reach into a receiver ends here.
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

    /// @notice Who may approve a hash here: this receiver's transmitter, or a payload this
    ///         receiver is already executing.
    function _checkCommitter() internal view override {
        if (!isAuthorizedCaller(msg.sender)) revert NotSourceTransmitter();
    }

    /// @notice Withdraw an approval so it can never be finalized.
    /// @dev Gated like `commit`, which already lets the caller approve any array. An absent
    ///      approval reverts, since success would suggest a payload was stopped that may have
    ///      run. See `InboundBase._cancel`.
    function cancel(bytes32 commitment_) external virtual override onlySourceTransmitter {
        _cancel(commitment_);
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

    /* ================================== inbound ================================= */

    /// @notice Split a canonical opaque element into its target, value, and calldata.
    function _decodeCall(bytes calldata call) internal pure returns (address target, uint256 value, bytes memory data) {
        Call memory c = Calls.decode(call);
        return (c.target, c.value, c.data);
    }

    /// @notice Accept a delivery only from this receiver's own transmitter.
    ///
    /// @dev Compares against the stored `sourceTransmitter`, not `address(this)`, mirroring
    ///      `TransmitterBase._requireOwnRecipient`. It is the second check in front of
    ///      `receiveMessage`: the gateway role says the transport is trusted, this says the
    ///      message came from this account, so a shared gateway cannot land one account's
    ///      payload in another's receiver.
    function _authenticateSender(bytes calldata sender) internal view override {
        if (_senderAddress(sender) != sourceTransmitter) {
            revert SenderIsNotThisAccount(sender);
        }
    }

    /// @notice Accept ETH, so a receiver can be funded ahead of a `finalize` that spends it.
    /// @dev `finalize` is permissionless and carries no value, so a payload with value
    ///      finalized by a third party spends this balance. The address is known before the
    ///      receiver exists, so a shortfall is fixed by topping up and retrying.
    receive() external payable {}
}
