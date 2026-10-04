// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Call} from "src/messaging/Call.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";

/// @notice What a symmetric transceiver is configured with, once, at initialization.
/// @dev A struct, not loose arguments: initializers sit near the stack limit at `paris`.
struct TransceiverConfig {
    address[] gateways;
    address transmitterImplementation;
    address receiverImplementation;
    /// The crossecute msig's own account, named by its owner, salt, and home: its transmitter
    /// on that home, its receiver everywhere else. It owns this transceiver.
    address governorOwner;
    bytes32 governorSalt;
    bytes32 governorHome;
    /// Where bootstrap fees go and the report float leaves to. Write-once.
    address treasury;
}

/// @title SymmetricTransceiverBase
/// @notice One transceiver per chain per provider, as hub and spoke at once. It creates
///         transmitters for accounts homed here and receivers for accounts homed on any
///         configured origin, and it sends and accepts both bootstraps and receiver reports.
///
/// @dev Extends the hub, whose routes, counterparts, registry and provenance bar, bootstrap
///      fee, treasury, report receipt, and `createTransmitter` all apply unchanged. What this
///      adds is the spoke's half, with the account's home taken from the authenticated origin
///      rather than from one stored value.
///
/// @dev Owned by the crossecute msig's own account on this chain, derived at initialization
///      rather than typed, and configured by payloads the msig sends from its home.
abstract contract SymmetricTransceiverBase is HubTransceiverBase {
    /// The receiver logic every account homed elsewhere is armed with. Write-once.
    address public receiverImplementation;

    /// Whether account addresses here differ from Ethereum's CREATE2. When true, every receiver
    /// created here is reported to its home, which cannot derive it. Write-once, and set by the
    /// contract rather than its caller, so it cannot disagree with `predictCrossAccount`.
    bool public addressesDiverge;

    /// True only while a receiver report is being sent, which pays from this contract's float.
    bool private _reporting;

    event ReceiverImplementationSet(address implementation);
    event AddressesDivergeSet(bool addressesDiverge);
    event ReceiverReported(bytes32 indexed home, address indexed owner, bytes32 salt, address receiver);
    event Withdrawn(address indexed to, uint256 amount);

    /// @dev An EVM receiver can only answer to an EVM transmitter.
    error SourceTransmitterNotEvm(bytes32 transmitter);
    /// @dev A receiver homed on a `Derived` chain landed off its transmitter's address, so the
    ///      origin's provider id, route, or transceiver address disagree with this chain's.
    ///      Refused on the first bootstrap rather than leaving every such account unreachable.
    error ParityBroken(address receiver, address sourceTransmitter);
    error NotTreasury(address caller);
    error WithdrawFailed(uint256 amount);

    /// @notice For a transceiver that derives account addresses Ethereum's way.
    function __SymmetricTransceiver_init(TransceiverConfig memory c) internal onlyInitializing {
        __SymmetricTransceiver_init(c, false);
    }

    /// @dev `addressesDiverge_` is the contract's own fact: `DivergentSymmetricTransceiver`
    ///      passes true, having set its derivation inputs first, since the owner is derived here
    ///      with `predictCrossAccount`.
    function __SymmetricTransceiver_init(TransceiverConfig memory c, bool addressesDiverge_) internal onlyInitializing {
        if (c.receiverImplementation == address(0)) revert NoAccountImplementation();
        if (c.treasury == address(0)) revert NoTreasury();
        if (c.governorOwner == address(0)) revert ZeroOwner();

        receiverImplementation = c.receiverImplementation;
        emit ReceiverImplementationSet(c.receiverImplementation);

        addressesDiverge = addressesDiverge_;
        emit AddressesDivergeSet(addressesDiverge_);

        // Last, and the transceiver is sealed. See `TransceiverBase.__TransceiverBase_init`.
        __HubTransceiverBase_init(
            predictCrossAccount(c.governorOwner, c.governorSalt, c.governorHome),
            c.treasury,
            c.gateways,
            c.transmitterImplementation
        );
    }

    /* ============================= account manufacture ========================== */

    /// @inheritdoc HubTransceiverBase
    function _accountImplementation(bytes32 homeChainKey) internal view virtual override returns (address) {
        return homeChainKey == localChainKey ? transmitterImplementation : receiverImplementation;
    }

    /// @inheritdoc HubTransceiverBase
    /// @dev A receiver answers to the transmitter its bootstrap carried.
    function _accountInitializer(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls
    ) internal view virtual override returns (bytes memory) {
        if (homeChainKey == localChainKey) {
            return super._accountInitializer(owner, salt, homeChainKey, sourceTransmitter, calls);
        }
        return abi.encodeCall(IReceiverInit.initialize, (sourceTransmitter, calls));
    }

    /* ================================== inbound ================================= */

    /// @inheritdoc HubTransceiverBase
    /// @dev A report goes to the hub's handler. A bootstrap creates a receiver homed on the
    ///      authenticated origin, never on a chain the message states.
    function _handleInbound(bytes32 origin, bytes calldata message) internal virtual override {
        if (Envelope.kindOf(message) == Envelope.RECEIVER_REPORT) {
            super._handleInbound(origin, message);
            return;
        }

        (address owner, bytes32 salt, bytes32 transmitter, Call[] memory calls) = Envelope.decodeBootstrap(message);
        if (uint256(transmitter) >> 160 != 0) revert SourceTransmitterNotEvm(transmitter);
        _bootstrapInbound(owner, salt, origin, address(uint160(uint256(transmitter))), calls);
    }

    /// @notice Stand up the receiver of an account homed on `home`, and run its first payload.
    ///
    /// @dev Never deferred: the receiver is created and its payload run in the delivery that
    ///      carries them, reachable only from an authenticated `_onInbound`.
    ///
    /// @dev Where this chain diverges, the home cannot derive the receiver, so it is reported.
    ///      Otherwise, if the home is `Derived`, the receiver must sit at its transmitter's
    ///      address; a home graded below that (zkSync, Tron) has its transmitter elsewhere.
    function _bootstrapInbound(
        address owner,
        bytes32 salt,
        bytes32 home,
        address sourceTransmitter,
        Call[] memory calls
    ) internal {
        address receiver = _createCrossAccount(owner, salt, home, sourceTransmitter, calls);
        if (addressesDiverge) {
            _reportReceiver(home, owner, salt, receiver);
        } else if (receiver != sourceTransmitter && chainRegistry.provenanceFor(home) == Provenance.Derived) {
            revert ParityBroken(receiver, sourceTransmitter);
        }
    }

    /* ================================= the report ================================ */

    /// @notice Tell the account's home where its receiver landed.
    /// @dev Paid from this contract's float, since it is nested in a delivery where
    ///      `msg.value` is zero. A failed send reverts the account creation with it, which
    ///      keeps the bootstrap retryable once the float is topped up.
    function _reportReceiver(bytes32 home, address owner, bytes32 salt, address receiver) internal {
        emit ReceiverReported(home, owner, salt, receiver);

        bytes memory recipient = _recipientOn(home);
        bytes memory payload = reportPayload(owner, salt, receiver);

        _reporting = true;
        _sendMessage(recipient, payload, new bytes[](0), _quoteMessage(recipient, payload, new bytes[](0)));
        _reporting = false;
    }

    /// @notice The exact report bytes for `(owner, salt)` and `receiver`, so its cost can be
    ///         quoted with `quoteMessage` before it is owed.
    function reportPayload(address owner, bytes32 salt, address receiver) public view returns (bytes memory) {
        return Envelope.encodeReceiverReport(owner, salt, Erc7930.encodeEvm(block.chainid, receiver));
    }

    /// @notice Where a provider returns an overpaid fee: whoever paid it.
    /// @dev A report's overpayment returns to the float it was paid from. Anything else, a
    ///      bootstrap above all, refunds the account that paid.
    function _refundTo() internal view virtual override returns (address) {
        return _reporting ? address(this) : msg.sender;
    }

    /* ================================== the float ================================= */

    /// @notice Accept the float reports are paid from.
    receive() external payable {}

    /// @notice Send `amount` of the float to the treasury, at the treasury's call.
    /// @dev Gated, not a permissionless sweep: anyone able to empty the float could make every
    ///      bootstrap here that reports revert.
    function withdraw(uint256 amount) external {
        address to = treasury;
        if (msg.sender != to) revert NotTreasury(msg.sender);

        emit Withdrawn(to, amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailed(amount);
    }
}
