// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Call} from "src/messaging/Call.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";

/// @title SpokeTransceiverBase
/// @notice Every chain that is not the home chain. Exactly one counterpart, named at
///         initialization.
///
/// @dev THE CARDINALITY IS THE WHOLE DESIGN. The hub holds N claims about where remote code
///      lives, so it needs a registry, a provenance grade per claim, and a routing table. A
///      spoke holds one, and it is not a claim at all. Every piece of resolution machinery
///      therefore collapses into a stored value, and the spoke carries no `chainRegistry`
///      pointer, no `minCounterpartProvenance`, and no routing table.
///
/// @dev THAT IS A SECURITY PROPERTY, NOT JUST A SAVING. A hub authenticates against an
///      N-entry peer set, which is mutable state an owner could repoint. A spoke's check is a
///      comparison against write-once values: there is no configuration by which it could be
///      made to accept a second origin, so the set of chains that can drive this contract is
///      fixed at INITIALIZATION and cannot be widened afterwards by anyone, the local msig
///      included.
///
/// @dev THE HOME CHAIN IS A PARAMETER, NOT ETHEREUM. A team can centralize on whichever chain
///      they are willing to anchor to. What the hub must be is an EVM chain with the EIP-152
///      precompile, because the registry recomputes addresses and commitments locally.
///
/// @dev THEY ARE INITIALIZER ARGUMENTS RATHER THAN CONSTANTS, AND THAT COSTS NOTHING. The
///      parity argument would object to an immutable set from a constructor argument, because
///      it lands in the deployed initcode; it does not apply here, since a transceiver is
///      deployed as a `CrossProxy` that takes no constructor arguments at all, and an
///      implementation's parameters never reach the proxy's initcode.
abstract contract SpokeTransceiverBase is TransceiverBase {
    /// keccak256 of the home chain's canonical ERC-7930 chain identifier: the one chain this
    /// spoke will accept a message from, and the only one it will send to.
    ///
    /// @dev For Ethereum mainnet (the expected home) this is `keccak256(0x00010000010100)`:
    ///      version 1, chainType eip155, a one-byte chain reference `0x01`, and a zero-length
    ///      address. `ChainKey.forEvm(1)` computes it.
    bytes32 public homeChainKey;

    /// The receiver logic every account here is armed with.
    ///
    /// @dev WRITE-ONCE, BECAUSE CHANGING IT IS NOT A CONFIG EDIT. An account's proxy locks the
    ///      moment it is armed, so a change moves no receiver that already exists: it only
    ///      affects transmitters whose receiver has not been created yet, silently forking
    ///      the population into two logic versions distinguishable only by when each user
    ///      first sent.
    address public receiverImplementation;

    /// Whether an account's address on THIS chain differs from the one the hub derives for
    /// it. When true, every account created here is reported home.
    ///
    /// @dev THE HUB CANNOT WORK THIS OUT, WHICH IS WHY IT IS STATED HERE. It derives a
    ///      receiver's address by recomputing Ethereum's CREATE2 formula over the recorded
    ///      factory, salt, and initcode hash: correct on most EVM chains and wrong on zkSync
    ///      and Tron, and the chain itself is the only party that knows which it is. A flag
    ///      says so once instead of leaving the hub to infer it from a provenance cap that
    ///      means something adjacent but not the same thing.
    ///
    /// @dev IT IS WHAT KEEPS THE REPORT OFF THE CHAINS THAT DO NOT NEED IT. On a parity chain
    ///      the hub computed the address before the first message went out, so a report would
    ///      spend a message to restate it and would DOWNGRADE what it knows, a derivation
    ///      being `Derived` and anything over a bridge `Attested`. Most spokes therefore send
    ///      nothing, and only the ones that must be believed have to be funded to speak.
    ///
    /// @dev WRITE-ONCE, LIKE EVERYTHING ELSE HERE. Flipping it later would either start
    ///      reporting addresses the hub already holds, or stop reporting ones it cannot
    ///      derive, and the second is silent: accounts would be created here that the home
    ///      chain can never address.
    bool public addressesDiverge;

    event ReceiverImplementationSet(address implementation);
    event HomeSet(bytes32 homeChainKey, bytes homeRoute, bytes homeTransceiver);
    event AddressesDivergeSet(bool addressesDiverge);
    /// @dev Fires on the chains that report, which is not most of them.
    event ReceiverReported(address indexed owner, bytes32 salt, address receiver);

    /// @dev A spoke's only destination is its home; anything else is a bug or an attempt to
    ///      make this contract talk to a sibling spoke, which the protocol has no path for.
    error NotHome(bytes32 chainKey);
    error NoHomeTransceiver();
    /// @dev Something that is not the hub tried to drive this contract.
    error NotHomeOrigin();
    error NoHomeChainKey();
    error NoHomeRoute();
    /// @dev The stated route does not hash to the stated home chainKey.
    error HomeRouteMismatch();

    /// @notice Bind this spoke to its hub, permanently.
    /// @dev All four values are written once and none has a setter, so neither the local msig
    ///      nor an upgrade of any other contract can widen the set of origins this spoke will
    ///      accept.
    /// @param addressesDiverge_ True only where an account's address here is NOT the one the
    ///        hub derives for it: zkSync and Tron among EVM chains. Leaving it false where it
    ///        should be true creates accounts the home chain can never address.
    function __SpokeTransceiverBase_init(
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes memory homeRoute_,
        bytes memory homeTransceiver_,
        bool addressesDiverge_
    ) internal onlyInitializing {
        if (homeChainKey_ == bytes32(0)) revert NoHomeChainKey();
        if (homeRoute_.length == 0) revert NoHomeRoute();
        // The route IS the chain identifier, so the pair cannot be allowed to disagree: a
        // chainKey is `keccak256(identifier)` by definition, and a spoke whose two halves
        // named different chains would authenticate against one and send to the other.
        if (ChainKey.fromIdentifier(homeRoute_) != homeChainKey_) revert HomeRouteMismatch();
        if (homeTransceiver_.length == 0) revert NoHomeTransceiver();
        if (receiverImplementation_ == address(0)) revert NoAccountImplementation();

        receiverImplementation = receiverImplementation_;
        emit ReceiverImplementationSet(receiverImplementation_);

        homeChainKey = homeChainKey_;
        _setRoute(homeChainKey_, homeRoute_);
        _setCounterpart(homeChainKey_, homeTransceiver_);
        emit HomeSet(homeChainKey_, homeRoute_, homeTransceiver_);

        addressesDiverge = addressesDiverge_;
        emit AddressesDivergeSet(addressesDiverge_);
    }

    /// @notice The hub transceiver, in THIS chain's address format.
    ///
    /// @dev IT IS `OutboundBase`'s COUNTERPART SLOT, written once in the initializer. Raw
    ///      bytes rather than `address` because a spoke may not be an EVM chain, and stored
    ///      rather than derived because the chains where a spoke most needs to be sure
    ///      (zkSync and Tron, and every non-EVM VM) are exactly the ones where a derivation
    ///      does not hold, and a spoke has no registry to ask.
    ///
    /// @dev WRITE-ONCE WITH NO SETTER AND NO LOCK. `OutboundBase._setCounterpart` is
    ///      rebindable and this contract simply never exposes it: a setter plus a lock would
    ///      leave a window in which the admin could repoint the one address this contract
    ///      authenticates every inbound message against, and writing it in the initializer
    ///      closes that window rather than documenting it. It costs nothing in practice,
    ///      since hub and spoke proxies share initcode and salt and so land on one address
    ///      wherever Ethereum's CREATE2 formula holds.
    function homeTransceiver() public view returns (bytes memory) {
        return OutboundBase._counterpartOn(homeChainKey);
    }

    /// @notice The home chain's ERC-7930 chain identifier.
    /// @dev Also `OutboundBase`'s, and write-once there by construction. The value is
    ///      approved by whoever signs the initialization rather than read out of a deploy
    ///      script afterwards, which is the same guarantee a source literal gave and the only
    ///      one available once the home chain is a choice rather than a constant.
    function homeRoute() public view returns (bytes memory) {
        return routeFor(homeChainKey);
    }

    /// @inheritdoc OutboundBase
    /// @dev THE TABLE HOLDS EXACTLY ONE ROW, AND THIS IS WHAT ENFORCES THAT. The base would
    ///      happily answer for any key that had been written; a spoke asked to route anywhere
    ///      but home reverts instead, which is what makes spoke-to-spoke traffic structurally
    ///      impossible rather than merely unconfigured.
    function _counterpartOn(bytes32 chainKey)
        internal
        view
        override
        returns (bytes memory)
    {
        if (chainKey != homeChainKey) revert NotHome(chainKey);
        return OutboundBase._counterpartOn(chainKey);
    }

    /// @inheritdoc OutboundBase
    function _routeTo(bytes32 chainKey) internal view override returns (bytes memory) {
        if (chainKey != homeChainKey) revert NotHome(chainKey);
        return OutboundBase._routeTo(chainKey);
    }

    /// @inheritdoc TransceiverBase
    /// @dev ONE ORIGIN, SO IT IS A COMPARISON. Both halves are write-once, so there is no
    ///      lookup that could return the wrong answer if configuration drifted and no
    ///      configuration by which this could be made to accept a second origin.
    function _authenticateOrigin(bytes memory route, bytes memory sender)
        internal
        view
        override
        returns (bytes32)
    {
        if (!_isHome(route, sender)) revert NotHomeOrigin();
        return homeChainKey;
    }

    /// @inheritdoc TransceiverBase
    /// @dev A spoke receives bootstrap messages and nothing else. The chainKey is discarded:
    ///      it is `homeChainKey` or `_authenticateOrigin` already reverted.
    function _handleInbound(bytes32, bytes calldata message) internal override {
        (address owner, bytes32 salt, Call[] memory calls) =
            Envelope.decodeBootstrap(message);
        this.bootstrapInbound(owner, salt, calls);
    }

    /// @notice Whether an inbound message's origin is the hub, in one comparison.
    function _isHome(bytes memory route, bytes memory sender) internal view returns (bool) {
        return keccak256(route) == keccak256(homeRoute())
            && keccak256(sender) == keccak256(homeTransceiver());
    }

    /* ============================ receiver manufacture ========================= */

    /// @inheritdoc TransceiverBase
    /// @dev A SPOKE INSTALLS A RECEIVER, and that is deliberately the only thing that differs
    ///      from the hub: the proxy, the salt, and the deployer address are identical on both
    ///      sides, so an owner's transmitter and receiver land on one address.
    function _accountImplementation() internal view virtual override returns (address) {
        return receiverImplementation;
    }

    /// @inheritdoc TransceiverBase
    /// @dev THE RECEIVER'S PEER IS ITS OWN ADDRESS, since a transmitter and its receivers
    ///      share one. Passing it explicitly rather than assuming `address(this)` keeps the
    ///      peer a stored fact, so nothing breaks if the two ever diverge.
    function _accountInitializer(address owner, bytes32 salt, Call[] memory calls)
        internal
        view
        virtual
        override
        returns (bytes memory)
    {
        return abi.encodeCall(
            IReceiverInit.initialize, (predictCrossAccount(owner, salt), calls)
        );
    }

    /// @notice Inbound path: stand this owner's receiver up and run the payload that
    ///         justified doing so.
    ///
    /// @dev SELF-CALL ONLY, so it is reachable from `_onInbound` (which authenticates the
    ///      origin) and nowhere else.
    ///
    /// @dev IT CREATES AND INITIALIZES, AND THAT IS ITS ENTIRE RELATIONSHIP WITH A RECEIVER.
    ///      The transceiver never calls `commit`, `finalize`, or `execute` afterwards and
    ///      holds no upgrade key past this transaction. Relaying approvals instead would make
    ///      it a standing authority over every receiver it had ever created, when the only
    ///      thing it needs authority for is the first message. A payload that should wait
    ///      says so itself by carrying a self-call to the receiver's `commit`, so there is no
    ///      second entry point for the deferred case.
    ///
    /// @dev THERE IS NO PERMISSIONLESS CREATION PATH. An account on a spoke exists because a
    ///      bootstrap message arrived, and nothing else. An open one would let anyone deploy
    ///      an owner's account empty, one transaction ahead of their bootstrap, and
    ///      permanently deny it: `CrossProxy` arms exactly once.
    ///
    /// @dev THE SALT CROSSES WITH THE OWNER, AND IT HAS TO: the account address is
    ///      `(owner, salt)`, so a spoke that only knew the owner could not reproduce the
    ///      address its transmitter occupies at home, which is the entire property.
    function bootstrapInbound(address owner, bytes32 salt, Call[] calldata calls)
        external
    {
        require(msg.sender == address(this));
        address receiver = _createCrossAccount(owner, salt, calls);
        if (addressesDiverge) _reportReceiver(owner, salt, receiver);
    }

    /* ================================ the report =============================== */

    /// @notice Tell the hub where the receiver actually landed.
    ///
    /// @dev ONLY WHERE THE HUB COULD NOT WORK IT OUT: see `addressesDiverge`. It names the
    ///      PAIR, not the address alone, because `(owner, salt)` is what an account IS and on
    ///      this chain the address is a different derivation of it. The hub derives the
    ///      registry slot from the pair plus the origin it already authenticated, so the
    ///      destination cannot choose which slot it writes, and the slot is write-once, so a
    ///      replayed report is a no-op rather than a repoint. That is why no request id is
    ///      needed.
    ///
    /// @dev IT IS PAID FROM THIS CONTRACT'S BALANCE, AND THAT IS THE COST OF THE FLAG. The
    ///      send is nested inside a delivery callback, where `msg.value` is zero, so a
    ///      diverging spoke has to be funded by whoever operates it.
    ///
    /// @dev THE REVERT IS CORRECT, AND MUST NOT BE SWALLOWED. It takes the account creation
    ///      down with it, which is what makes the bootstrap retryable once the balance is
    ///      topped up. Catching the failure would create an account here and leave the hub
    ///      permanently unable to address it: `CrossProxy` arms exactly once and `initialize`
    ///      is single-shot, so there is no second bootstrap to carry a second report.
    function _reportReceiver(address owner, bytes32 salt, address receiver) internal {
        emit ReceiverReported(owner, salt, receiver);
        _sendMessage(
            _recipientOn(homeChainKey),
            Envelope.encodeReceiverReport(
                owner, salt, Erc7930.encodeEvm(block.chainid, receiver)
            ),
            new bytes[](0)
        );
    }
}
