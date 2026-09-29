// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Call} from "src/messaging/Call.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";

/// @title SpokeTransceiverBase
/// @notice Every chain that is not the home chain. Exactly one counterpart, named at
///         initialization.
///
/// @dev With one counterpart there is no registry, provenance bar, or routing table. The
///      origin check is a comparison against write-once values, so no one, the local msig
///      included, can widen the set of chains that drive this contract after initialization.
///
/// @dev The home chain is an initializer argument, not Ethereum. The hub must be an EVM chain
///      with the EIP-152 precompile, since the registry recomputes addresses and commitments
///      locally. Initializer arguments never reach `CrossProxy`'s initcode, so they cost
///      parity nothing.
abstract contract SpokeTransceiverBase is TransceiverBase {
    /// keccak256 of the home chain's canonical ERC-7930 chain identifier: the one chain this
    /// spoke accepts messages from and sends to. `ChainKey.forEvm(1)` for Ethereum mainnet.
    bytes32 public homeChainKey;

    /// The receiver logic every account here is armed with.
    /// @dev Write-once: accounts lock when armed, so a change would split them into two logic
    ///      versions by creation time.
    address public receiverImplementation;

    /// Whether an account's address on this chain differs from the one the hub derives for
    /// it. When true, every account created here is reported home.
    ///
    /// @dev Stated here because the hub cannot tell: it recomputes Ethereum's CREATE2, which is
    ///      wrong on zkSync and Tron. On a parity chain a report would only restate the hub's
    ///      `Derived` address as an `Attested` one.
    ///
    /// @dev Write-once. Clearing it where it should be set would create accounts the home
    ///      chain can never address, silently.
    bool public addressesDiverge;

    event ReceiverImplementationSet(address implementation);
    event HomeSet(bytes32 homeChainKey, bytes homeRoute, bytes homeTransceiver);
    event AddressesDivergeSet(bool addressesDiverge);
    event ReceiverReported(address indexed owner, bytes32 salt, address receiver);

    /// @dev A spoke's only destination is its home; there is no spoke-to-spoke path.
    error NotHome(bytes32 chainKey);
    error NoHomeTransceiver();
    /// @dev The hub is an EVM contract, and its address is cast to `address` for the home
    ///      transmitter and LayerZero's peer: any other width would truncate or pad silently.
    error InvalidHomeTransceiverLength();
    /// @dev Something that is not the hub tried to drive this contract.
    error NotHomeOrigin();
    error NoHomeChainKey();
    error NoHomeRoute();
    /// @dev The stated route does not hash to the stated home chainKey.
    error HomeRouteMismatch();

    /// @notice Bind this spoke to its hub, permanently.
    /// @dev Home chainKey, route, transceiver, and receiver implementation are written once
    ///      with no setter. There is no treasury: a spoke charges nothing and holds only the
    ///      float for its reports.
    /// @param addressesDiverge_ True only where an account's address here is not the one the
    ///        hub derives: zkSync and Tron among EVM chains.
    function __SpokeTransceiverBase_init(
        address[] memory gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes memory homeRoute_,
        bytes memory homeTransceiver_,
        bool addressesDiverge_
    ) internal onlyInitializing {
        if (homeChainKey_ == bytes32(0)) revert NoHomeChainKey();
        if (homeRoute_.length == 0) revert NoHomeRoute();
        // A spoke whose route and chainKey named different chains would authenticate against
        // one and send to the other.
        if (ChainKey.fromIdentifier(homeRoute_) != homeChainKey_) revert HomeRouteMismatch();
        if (homeTransceiver_.length == 0) revert NoHomeTransceiver();
        if (homeTransceiver_.length != 20) revert InvalidHomeTransceiverLength();
        if (receiverImplementation_ == address(0)) revert NoAccountImplementation();

        receiverImplementation = receiverImplementation_;
        emit ReceiverImplementationSet(receiverImplementation_);

        homeChainKey = homeChainKey_;
        _setRoute(homeChainKey_, homeRoute_);
        _setCounterpart(homeChainKey_, homeTransceiver_);
        emit HomeSet(homeChainKey_, homeRoute_, homeTransceiver_);

        addressesDiverge = addressesDiverge_;
        emit AddressesDivergeSet(addressesDiverge_);

        // Last, and the spoke is sealed. See `TransceiverBase.__TransceiverBase_init`.
        __TransceiverBase_init(gateways);
    }

    /// @notice The hub transceiver, in this chain's address format.
    /// @dev `OutboundBase`'s counterpart on `homeChainKey`, written in the initializer and
    ///      never again: the spoke exposes no `_setCounterpart` path. Stored rather than
    ///      derived, since a spoke has no registry.
    function homeTransceiver() public view returns (bytes memory) {
        return OutboundBase._counterpartOn(homeChainKey);
    }

    /// @notice `_onInbound` from home, for a binding that has already checked the delivery's
    ///         origin chain (`ProviderOrigin`) and reports the sender as a plain address.
    function _onHomeInbound(address sender, bytes calldata message) internal {
        _onInbound(homeRoute(), abi.encodePacked(sender), message);
    }

    /// @notice Where `(owner, salt)`'s transmitter lives on the home chain: Ethereum's CREATE2
    ///         over the hub's address, which the hub itself deploys with.
    /// @dev A receiver's `sourceTransmitter`. Not `predictCrossAccount`, which on zkSync and
    ///      Tron is the receiver's own address under this chain's formula.
    function homeTransmitterOf(address owner, bytes32 salt) public view returns (address) {
        return Create2.computeAddress(
            accountSalt(owner, salt), CROSS_PROXY_INIT_CODE_HASH, address(bytes20(homeTransceiver()))
        );
    }

    /// @notice The home chain's ERC-7930 chain identifier.
    function homeRoute() public view returns (bytes memory) {
        return routeFor(homeChainKey);
    }

    /// @inheritdoc OutboundBase
    /// @dev Refuses every key but home, which makes spoke-to-spoke traffic impossible rather
    ///      than unconfigured.
    function _counterpartOn(bytes32 chainKey) internal view override returns (bytes memory) {
        if (chainKey != homeChainKey) revert NotHome(chainKey);
        return OutboundBase._counterpartOn(chainKey);
    }

    /// @inheritdoc OutboundBase
    function _routeTo(bytes32 chainKey) internal view override returns (bytes memory) {
        if (chainKey != homeChainKey) revert NotHome(chainKey);
        return OutboundBase._routeTo(chainKey);
    }

    /// @inheritdoc TransceiverBase
    function _authenticateOrigin(bytes memory route, bytes memory sender) internal view override returns (bytes32) {
        if (!_isHome(route, sender)) revert NotHomeOrigin();
        return homeChainKey;
    }

    /// @inheritdoc TransceiverBase
    /// @dev A spoke receives bootstraps only. The chainKey can only be `homeChainKey`.
    function _handleInbound(bytes32, bytes calldata message) internal virtual override {
        (address owner, bytes32 salt, Call[] memory calls) = Envelope.decodeBootstrap(message);
        this.bootstrapInbound(owner, salt, calls);
    }

    /// @notice Whether an inbound message's origin is the hub.
    function _isHome(bytes memory route, bytes memory sender) internal view returns (bool) {
        return keccak256(route) == keccak256(homeRoute()) && keccak256(sender) == keccak256(homeTransceiver());
    }

    /* ============================ receiver manufacture ========================= */

    /// @inheritdoc TransceiverBase
    function _accountImplementation() internal view virtual override returns (address) {
        return receiverImplementation;
    }

    /// @inheritdoc TransceiverBase
    /// @dev The receiver authenticates `homeTransmitterOf(owner, salt)`.
    function _accountInitializer(address owner, bytes32 salt, Call[] memory calls)
        internal
        view
        virtual
        override
        returns (bytes memory)
    {
        return abi.encodeCall(IReceiverInit.initialize, (homeTransmitterOf(owner, salt), calls));
    }

    /// @notice What an arriving payload may call here: `TransceiverBase`'s two, plus
    ///         `bootstrapInbound`, which a deferred bootstrap's finalized array calls.
    function isAllowed(address target, bytes4 selector) public view virtual override returns (bool) {
        if (target == address(this) && selector == this.bootstrapInbound.selector) {
            return true;
        }
        return super.isAllowed(target, selector);
    }

    /// @notice Inbound path: stand this owner's receiver up and run its bootstrap payload.
    ///
    /// @dev Self-call only, so reachable only from an authenticated `_onInbound`. An open
    ///      creation path would let anyone deploy an owner's account empty ahead of their
    ///      bootstrap, and `CrossProxy` arms once.
    ///
    /// @dev Creation is the transceiver's whole relationship with a receiver: it never calls
    ///      `commit`, `finalize`, or `execute` afterwards. A payload that should wait carries a
    ///      self-call to the receiver's `commit`.
    function bootstrapInbound(address owner, bytes32 salt, Call[] calldata calls) external {
        require(msg.sender == address(this));
        address receiver = _createCrossAccount(owner, salt, calls);
        if (addressesDiverge) _reportReceiver(owner, salt, receiver);
    }

    /* ================================ the report =============================== */

    /// @notice Tell the hub where the receiver actually landed.
    ///
    /// @dev Only where `addressesDiverge`. It names `(owner, salt)`, not the address alone:
    ///      the hub derives the account from that pair, so a destination cannot choose which
    ///      account it writes, and the account refuses a second report.
    ///
    /// @dev Paid from this contract's balance, since the send is nested in a delivery callback
    ///      where `msg.value` is zero; a diverging spoke must be funded by its operator.
    ///
    /// @dev A failed send must revert the account creation with it, which keeps the bootstrap
    ///      retryable once the balance is topped up. Swallowing it would leave an account the
    ///      hub can never address: `CrossProxy` arms once, so no second bootstrap can report.
    function _reportReceiver(address owner, bytes32 salt, address receiver) internal {
        emit ReceiverReported(owner, salt, receiver);

        bytes memory recipient = _recipientOn(homeChainKey);
        bytes memory payload = reportPayload(owner, salt, receiver);

        _sendMessage(recipient, payload, new bytes[](0), _quoteMessage(recipient, payload, new bytes[](0)));
    }

    /// @notice The exact report bytes this spoke would send for `(owner, salt)` and
    ///         `receiver`, so its cost can be quoted with `quoteMessage` before it is owed.
    /// @dev On the live path `receiver` is `predictCrossAccount(owner, salt)`, taken
    ///      explicitly so an overridden derivation quotes the value it reports.
    function reportPayload(address owner, bytes32 salt, address receiver) public view returns (bytes memory) {
        return Envelope.encodeReceiverReport(owner, salt, Erc7930.encodeEvm(block.chainid, receiver));
    }
}
