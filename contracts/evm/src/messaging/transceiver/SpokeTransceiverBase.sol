// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Envelope} from "src/messaging/Envelope.sol";
import {Call} from "src/messaging/Call.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {CrossProxy, ICrossProxy} from "src/factories/CrossProxy.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";

/// @title SpokeTransceiverBase
/// @notice Every chain that is not the home chain. Exactly one counterpart, named at
///         initialization.
///
/// @dev THE CARDINALITY IS THE WHOLE DESIGN. The hub holds N claims about where remote
///      code lives, so it needs a registry, a provenance grade per claim, and a routing
///      table. A spoke holds one, and it is not a claim at all: its home's chainKey is
///      written into this contract once and never again. Every piece of resolution
///      machinery therefore collapses into a stored value, and the spoke carries no
///      `chainRegistry` pointer, no `minCounterpartProvenance`, and no chainKey => eid map.
///
/// @dev THAT IS A SECURITY PROPERTY, NOT JUST A SAVING. A hub must authenticate inbound
///      messages against an N-entry peer set, which is mutable state an owner could
///      repoint. A spoke's check is a comparison against a constant: there is no
///      configuration by which it could be made to accept a second origin, so the set of
///      chains that can drive this contract is fixed at INITIALIZATION and cannot be
///      widened by anyone afterwards, including the local msig. All three halves of the
///      home (its chainKey, the provider's route to it, and the counterpart address)
///      are written once in the initializer, with no setter to follow any of them.
///
/// @dev THE HOME CHAIN IS A PARAMETER, NOT ETHEREUM. Ethereum is the expected choice and
///      the reason the protocol is described that way, but nothing here requires it: a
///      team can centralize on whichever chain they are willing to anchor to, and every
///      spoke simply names that chain instead. What the hub must be is an EVM chain with
///      the EIP-152 precompile, because the registry recomputes addresses and commitments
///      locally: see `ChainRegistry` and `Commitment`.
///
/// @dev THEY ARE INITIALIZER ARGUMENTS RATHER THAN CONSTANTS, AND THAT COSTS NOTHING NOW.
///      A constant used to be the stronger choice, on the argument that an immutable set
///      from a constructor argument lands in the deployed initcode and CREATE2 parity
///      needs byte-identical initcode everywhere. That does not apply: a transceiver is
///      deployed as an `CrossProxy`, which takes no constructor arguments at all, and an
///      implementation's parameters never reach the proxy's initcode. The parity argument
///      is unaffected, and the write-once-at-initialization property is the same one
///      `_homeTransceiver` already relied on.
abstract contract SpokeTransceiverBase is TransceiverBase {
    /// keccak256 of the home chain's canonical ERC-7930 chain identifier: the one chain
    /// this spoke will accept a message from, and the only one it will send to.
    ///
    /// @dev For Ethereum mainnet (the expected home), this is
    ///      `keccak256(0x00010000010100)`: version 1,
    ///      chainType eip155, a one-byte chain reference `0x01`, and a zero-length
    ///      address. `ChainKey.forEvm(1)` computes it.
    bytes32 public homeChainKey;

    /// The message provider's own identifier for the home chain: a LayerZero eid, a
    /// Hyperlane domain, a Wormhole chain id. Opaque here; the binding decodes it.
    bytes private _homeRoute;

    /// The hub transceiver, in THIS chain's address format. Set at
    /// initialization, never after.
    ///
    /// @dev Storage rather than a constant only because it cannot be known before the hub
    ///      is deployed, and raw bytes rather than `address` because a spoke may not be an
    ///      EVM chain.
    ///
    /// @dev SET ONCE, WITH NO SETTER AND NO LOCK. A setter plus a lock would leave a
    ///      window: between the two calls the admin could repoint the one address this
    ///      contract authenticates every inbound message against. Writing it in the
    ///      initializer closes that window rather than
    ///      documenting it: there is no reachable state in which the value has been set
    ///      and can still be changed.
    ///
    ///      It costs nothing in practice. The hub address is knowable before the spoke is
    ///      initialized: hub and spoke proxies share initcode and salt, so on every EVM
    ///      chain sharing Ethereum's CREATE2 formula they land on the same address, and
    ///      the value is a `predictTransceiver` call rather than a deployment ordering
    ///      constraint.
    ///
    /// @dev SPLITTING HUB FROM SPOKE DID NOT MOVE ANY ADDRESS, DESPITE THE DIFFERENT
    ///      BYTECODE. A transceiver is deployed as a PROXY through Nick's factory, so the
    ///      CREATE2 initcode is the proxy's (with the deployer as owner and the factory
    ///      as the placeholder implementation), and is byte-identical for a hub and a
    ///      spoke. They diverge only in what they are upgraded to afterwards, which the
    ///      address derivation never sees. On every EVM chain sharing Ethereum's CREATE2
    ///      formula the hub and all spokes therefore land on the SAME address.
    ///
    ///      The registry's side of that still holds for the same reason: deriving a spoke
    ///      needs every spoke to be identical to the OTHER SPOKES, not to the hub, so one
    ///      `resolveEvmCreate2` at `Derived` covers every EVM destination at once. The
    ///      params must be the proxy's initcode hash, not an implementation's.
    ///
    ///      So why is this set rather than derived? Because the chains where a spoke most
    ///      needs to be sure (zkSync and Tron, whose CREATE2 formulas differ, and every
    ///      non-EVM VM) are exactly the ones where the derivation does not hold, and a
    ///      spoke has no registry to ask. One write at initialization is both simpler and
    ///      stronger than a derivation with three exceptions baked into it.
    bytes private _homeTransceiver;

    /// The receiver logic every clone delegates to. Set at initialization, never after.
    ///
    /// @dev WRITE-ONCE, BECAUSE CHANGING IT IS NOT A CONFIG EDIT. Clone bytecode has the
    ///      implementation address baked in, so a change moves no receiver that already
    ///      exists: it only affects transmitters whose receiver has not been deployed
    ///      yet, silently forking the population into two logic versions distinguishable
    ///      only by when each user first sent. A setter makes that one transaction away;
    ///      an initializer makes it a redeploy, which is what a change of this kind is.
    address public receiverImplementation;


    event ReceiverImplementationSet(address implementation);
    /// @dev Fires on the one message that stands a receiver up. There is no later inbound
    ///      event, because there is no later inbound message for a transceiver.
    event ReceiverBootstrapped(
        address indexed transmitter, address indexed receiver, uint256 callCount
    );
    /// @dev Fires once per transmitter, on the message that actually creates the clone.
    event ReceiverDeployed(address indexed transmitter, address indexed receiver);
    event HomeSet(bytes32 homeChainKey, bytes homeRoute, bytes homeTransceiver);

    /// @dev The only destination a spoke has is its home; anything else is a bug or an
    ///      attempt to make this contract talk to a sibling spoke, which the protocol
    ///      has no path for.
    error NotHome(bytes32 chainKey);
    error NoHomeTransceiver();
    /// @dev Something that is not the hub tried to drive this contract.
    error NotHomeOrigin();
    error NoHomeChainKey();
    error NoHomeRoute();
    /// @dev Bootstrap is for a chain with no receiver. One already exists, so its payload
    ///      cannot be delivered through `initialize` (that is single-shot), and this
    ///      contract has no other way to reach a receiver by design.
    error ReceiverAlreadyExists(address transmitter, address receiver);
    /// @dev Creating a receiver for a transmitter you do not control would deny it its
    ///      bootstrap: `initialize` is single-shot and an existing receiver cannot be
    ///      bootstrapped.
    error NotTransmitterOwner(address transmitter, address caller);

    /// @notice Bind this spoke to its hub, permanently.
    /// @dev All three values are written once and none has a setter, so neither the local
    ///      msig nor an upgrade of any other contract can widen the set of origins this
    ///      spoke will accept. There is no reachable state in which any of them has been
    ///      set and can still be changed.
    function __SpokeTransceiverBase_init(
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes memory homeRoute_,
        bytes memory homeTransceiver_
    ) internal onlyInitializing {
        if (homeChainKey_ == bytes32(0)) revert NoHomeChainKey();
        if (homeRoute_.length == 0) revert NoHomeRoute();
        if (homeTransceiver_.length == 0) revert NoHomeTransceiver();
        if (receiverImplementation_ == address(0)) revert NoAccountImplementation();

        receiverImplementation = receiverImplementation_;
        emit ReceiverImplementationSet(receiverImplementation_);

        homeChainKey = homeChainKey_;
        _homeRoute = homeRoute_;
        _homeTransceiver = homeTransceiver_;
        emit HomeSet(homeChainKey_, homeRoute_, homeTransceiver_);
    }

    function homeTransceiver() public view returns (bytes memory h) {
        h = _homeTransceiver;
        if (h.length == 0) revert NoHomeTransceiver();
    }

    /// @notice The message provider's own identifier for the home chain.
    /// @dev Set at initialization and never after. The value is approved by whoever signs
    ///      the initialization rather than read out of a deploy script afterwards, which
    ///      is the same guarantee a source literal gave and the only one available once
    ///      the home chain is a choice rather than a constant.
    function homeRoute() public view returns (bytes memory r) {
        r = _homeRoute;
        if (r.length == 0) revert NoHomeRoute();
    }

    /// @inheritdoc TransceiverBase
    /// @dev No lookup, no registry, no provenance: a comparison against a constant and
    ///      one read. A spoke asked to route anywhere but home reverts, which is what
    ///      makes spoke-to-spoke traffic structurally impossible rather than merely
    ///      unconfigured.
    function _counterpartOn(bytes32 chainKey)
        internal
        view
        override
        returns (bytes memory)
    {
        if (chainKey != homeChainKey) revert NotHome(chainKey);
        return homeTransceiver();
    }

    /// @inheritdoc TransceiverBase
    function _routeTo(bytes32 chainKey) internal view override returns (bytes memory) {
        if (chainKey != homeChainKey) revert NotHome(chainKey);
        return homeRoute();
    }

    /// @inheritdoc TransceiverBase
    ///
    /// @dev ONE ORIGIN, SO IT IS A COMPARISON. No registry, no provenance, no lookup that
    ///      could return the wrong answer if configuration drifted, and no configuration
    ///      by which this could be made to accept a second origin, since both halves are
    ///      write-once. The set of chains that can drive a spoke is fixed at deployment.
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
    /// @dev A spoke receives bootstrap messages and nothing else. The chainKey is
    ///      discarded: it is `homeChainKey` or `_authenticateOrigin` already reverted.
    function _handleInbound(bytes32, bytes calldata message) internal override {
        (address owner, bytes32 salt, Call[] memory calls) =
            Envelope.decodeBootstrap(message);
        this.bootstrapInbound(owner, salt, calls);
    }

    /// @notice Whether an inbound message's origin is the hub, in one comparison.
    /// @dev The spoke's entire peer check. `sender` is the raw counterpart address as the
    ///      provider reports it, and `route` the provider's source id, both compared
    ///      against values this contract cannot be reconfigured to widen.
    function _isHome(bytes memory route, bytes memory sender) internal view returns (bool) {
        return keccak256(route) == keccak256(homeRoute())
            && keccak256(sender) == keccak256(_homeTransceiver);
    }

    /* ============================ receiver manufacture ========================= */

    /// @inheritdoc TransceiverBase
    /// @dev A SPOKE INSTALLS A RECEIVER. That is the only thing that differs from the hub,
    ///      and it is deliberately the only thing: the proxy, the salt, and the deployer
    ///      address are identical on both sides, so an owner's transmitter and receiver
    ///      land on one address.
    function _accountImplementation() internal view virtual override returns (address) {
        return receiverImplementation;
    }

    /// @inheritdoc TransceiverBase
    /// @dev THE RECEIVER'S PEER IS ITS OWN ADDRESS. A transmitter and its receivers share
    ///      one address, so the contract at home that this receiver answers to sits at
    ///      exactly the address this receiver occupies here. Passing it explicitly rather
    ///      than assuming `address(this)` keeps the peer a stored fact, so nothing breaks
    ///      if the two ever diverge.
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
    ///      origin), and nowhere else.
    ///
    ///      IT CREATES AND INITIALIZES, AND THAT IS ITS ENTIRE RELATIONSHIP WITH A
    ///      RECEIVER. The transceiver never calls `commit`, `finalize`, or `execute`
    ///      afterwards, and holds no upgrade key past this transaction. Relaying approvals
    ///      instead would make it a standing authority over every receiver it had ever
    ///      created, when the only thing it needs authority for is the first message.
    ///
    /// @dev A PAYLOAD THAT SHOULD WAIT RATHER THAN RUN SAYS SO ITSELF, by carrying a
    ///      self-call to the receiver's `commit`. Nothing here has to know the difference,
    ///      which is why there is no second entry point for the deferred case.
    ///
    /// @dev THERE IS NO PERMISSIONLESS `createReceiver`. An account on a spoke exists
    ///      because a bootstrap message arrived, and nothing else. Leaving an open creation
    ///      path would let anyone deploy an owner's account empty, one transaction ahead of
    ///      their bootstrap, and permanently deny it: `CrossProxy` arms exactly once.
    /// @dev THE SALT CROSSES WITH THE OWNER, AND IT HAS TO. The account address is
    ///      `(owner, salt)`, so a spoke that only knew the owner could not reproduce the
    ///      address its transmitter occupies at home, which is the entire property.
    function bootstrapInbound(address owner, bytes32 salt, Call[] calldata calls)
        external
    {
        require(msg.sender == address(this));
        _createCrossAccount(owner, salt, calls);
    }
}
