// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {Provenance} from "src/registry/ForeignRef.sol";
import {IChainRegistryRoutes} from "src/registry/IChainRegistryRoutes.sol";
import {Call} from "src/messaging/Call.sol";

/// @notice What a hub needs from the transmitter logic it arms an account with.
interface ITransmitterInit {
    function initialize(address owner, address transceiver) external;
}

/// @title HubTransceiverBase
/// @notice The Ethereum side. One transceiver, N counterparts, one registry to tell them
///         apart.
///
/// @dev WHY THE REGISTRY IS ONLY EVER HERE. The fan-out is entirely one-directional: the
///      hub talks to every destination, and every destination talks only back to the hub.
///      A directory is what you need to hold N claims about where remote code lives and
///      how much each claim is worth; a spoke holds one, knows it at compile time, and
///      would gain nothing from the machinery but a mutable pointer to be compromised.
///      So `chainRegistry`, `messageProvider`, and the provenance dial live in this
///      contract and are absent from `SpokeTransceiverBase` entirely.
///
/// @dev THE HUB IS THE ONLY THING THAT GRADES. `minCounterpartProvenance` is a statement
///      about how much trust to place in a claim about a remote address — a question that
///      only arises when the address was learned rather than known. See
///      `SpokeTransceiverBase` for why the far side has no equivalent and needs none.
abstract contract HubTransceiverBase is TransceiverBase {
    /// The transmitter logic every account on this chain is armed with.
    ///
    /// @dev WRITE-ONCE, BECAUSE CHANGING IT FORKS THE POPULATION. An account's proxy is
    ///      locked the moment it is armed, so a change moves nobody who already has one —
    ///      it only affects owners who have not created theirs yet, splitting users into
    ///      two logic versions distinguishable only by when each arrived. That is a
    ///      redeploy, not a config edit.
    address public transmitterImplementation;

    event TransmitterImplementationSet(address implementation);

    /// The registry this transceiver asks where its counterparts live.
    IChainRegistryRoutes public chainRegistry;
    /// keccak256 of this transceiver's message provider name, e.g. "layerzero".
    bytes32 public messageProvider;
    /// The weakest counterpart provenance this transceiver will send to.
    /// @dev Every EVM counterpart is `Derived` — same CREATE2 address, recomputed on
    ///      Ethereum, no bridge trust. Chains where that breaks (Solana, Sui, Aptos,
    ///      Starknet, and also zkSync and Tron, whose CREATE2 formulas differ) can only
    ///      reach `Committed` or `Attested`, so this is the dial that decides whether
    ///      this transceiver is willing to talk to them at all.
    Provenance public minCounterpartProvenance;

    event DestinationReceiverReported(
        bytes32 indexed chainKey, address indexed transmitter, bytes32 slot
    );
    event RoutingSet(
        address chainRegistry, bytes32 messageProvider, Provenance minCounterpartProvenance
    );

    error NoChainRegistry();
    /// @dev The route resolved to a known chain, but the sender is not that chain's
    ///      counterpart — so either the wrong contract spoke, or the registry is stale.
    error NotCounterpart(bytes32 chainKey);

    function __HubTransceiverBase_init(address transmitterImplementation_)
        internal
        onlyInitializing
    {
        if (transmitterImplementation_ == address(0)) revert NoAccountImplementation();
        transmitterImplementation = transmitterImplementation_;
        emit TransmitterImplementationSet(transmitterImplementation_);
    }

    /* =========================== transmitter manufacture ======================= */

    /// @inheritdoc TransceiverBase
    /// @dev A HUB INSTALLS A TRANSMITTER. The only difference from the spoke, and
    ///      deliberately so — the proxy, the salt, and the deployer address are identical
    ///      on both sides, which is what puts an owner's transmitter and their receivers
    ///      on one address.
    function _accountImplementation() internal view override returns (address) {
        return transmitterImplementation;
    }

    /// @inheritdoc TransceiverBase
    /// @dev A transmitter takes no payload at creation. Its owner drives it directly and
    ///      can `execute` whenever it likes, so there is nothing a bootstrap payload would
    ///      be for on this side.
    function _accountInitializer(address owner, bytes32, Call[] memory)
        internal
        view
        override
        returns (bytes memory)
    {
        return abi.encodeCall(ITransmitterInit.initialize, (owner, address(this)));
    }

    /// @notice Create the caller's transmitter.
    ///
    /// @dev THE OWNER IS `msg.sender` BY CONSTRUCTION, NOT BY ARGUMENT. An owner passed in
    ///      could be anyone, and the derivation only means something if the party it names
    ///      is the party that asked for it. That binding is also what stops one party
    ///      squatting the address another intends to use — and here the address is not
    ///      merely theirs on this chain, it is theirs on every chain.
    /// @dev THE SALT IS THE CALLER'S, AND IT BUYS MORE THAN ONE ACCOUNT. An owner is not
    ///      limited to a single transmitter: one per purpose, per counterparty, per
    ///      mandate. Each `(msg.sender, salt)` pair is a distinct account with its own
    ///      address — and that address is theirs on every parity chain, not just this one.
    ///
    ///      It is hashed together with `msg.sender` rather than used raw, so one owner's
    ///      choice of salt can never land on another owner's account however it is chosen.
    ///
    /// @param salt Chosen by the caller. `bytes32(0)` is a perfectly good default for an
    ///        owner who wants exactly one account.
    /// @return account The transmitter, at the same address its receivers will occupy
    ///         everywhere else.
    function createTransmitter(bytes32 salt) external returns (address account) {
        account = _createXSafeAccount(msg.sender, salt, new Call[](0));
    }

    /// @notice Where `(owner, salt)`'s transmitter lives, before it exists.
    ///
    /// @dev THE POINT OF EXPOSING IT. An owner can compute the address they are about to
    ///      claim — on this chain and, because all three CREATE2 inputs are shared, on
    ///      every other one — before spending anything. It is also what lets an address be
    ///      pinned inside a payload approved before the account has been created.
    function predictTransmitter(address owner, bytes32 salt)
        external
        view
        returns (address)
    {
        return predictXSafeAccount(owner, salt);
    }

    /// @notice Point this transceiver at the registry, and state its provenance bar.
    function setRouting(
        IChainRegistryRoutes chainRegistry_,
        bytes32 messageProvider_,
        Provenance minCounterpartProvenance_
    ) external onlyAdmin {
        chainRegistry = chainRegistry_;
        messageProvider = messageProvider_;
        minCounterpartProvenance = minCounterpartProvenance_;
        emit RoutingSet(
            address(chainRegistry_), messageProvider_, minCounterpartProvenance_
        );
    }

    /// @inheritdoc TransceiverBase
    /// @dev The provenance bar is applied here, inside the registry read, rather than by
    ///      the caller — `transceiverFor` refuses anything below it.
    function _counterpartOn(bytes32 chainKey)
        internal
        view
        override
        returns (bytes memory counterpart)
    {
        if (address(chainRegistry) == address(0)) revert NoChainRegistry();
        (, counterpart) = chainRegistry.transceiverFor(
            chainKey, messageProvider, minCounterpartProvenance
        );
    }

    /// @inheritdoc TransceiverBase
    /// @dev Reverts with `NoProviderRoute` when unset rather than returning empty: an
    ///      unconfigured eid and an eid of zero are different states, and a send that
    ///      confused them would go into the void.
    function _routeTo(bytes32 chainKey) internal view override returns (bytes memory) {
        if (address(chainRegistry) == address(0)) revert NoChainRegistry();
        return chainRegistry.providerRoute(chainKey, messageProvider);
    }

    /// @inheritdoc TransceiverBase
    ///
    /// @dev N ORIGINS, SO IT IS A LOOKUP. The route names the chain and the registry names
    ///      that chain's counterpart, at this transceiver's provenance bar — so a hub
    ///      whose bar is `Derived` will not accept a message from a chain whose counterpart
    ///      is only `Attested`, however well-formed the message is. Both halves must agree:
    ///      an unknown route reverts in `chainKeyOfRoute`, and a known route with the wrong
    ///      sender reverts here.
    function _authenticateOrigin(bytes memory route, bytes memory sender)
        internal
        view
        override
        returns (bytes32 chainKey)
    {
        chainKey = _chainKeyOf(route);
        if (keccak256(sender) != keccak256(_counterpartOn(chainKey))) {
            revert NotCounterpart(chainKey);
        }
    }

    /// @inheritdoc TransceiverBase
    /// @dev A hub receives receiver reports and nothing else. Commitments travel the other
    ///      way, because transmitters live on Ethereum.
    function _handleInbound(bytes32 chainKey, bytes calldata message) internal override {
        (address transmitter, bytes memory interop) =
            Envelope.decodeReceiverReport(message);
        this.onDestinationReceiver(chainKey, transmitter, interop);
    }

    /// @notice Turn a provider's native source id back into a chain, on the inbound path.
    /// @dev The reverse of `_route`, and the reason the registry keeps a reverse index.
    ///      A provider hands over a raw source eid; nothing else in the protocol speaks
    ///      that language, so it is resolved once, here, at the edge.
    function _chainKeyOf(bytes memory route) internal view returns (bytes32) {
        if (address(chainRegistry) == address(0)) revert NoChainRegistry();
        return chainRegistry.chainKeyOfRoute(messageProvider, route);
    }

    /// @notice Inbound callback: the destination reports where it created the receiver.
    /// @dev THE ESCAPE HATCH FOR UNDERIVABLE CHAINS. Most destinations need nothing like
    ///      this — an EVM receiver is a CREATE2 clone whose address Ethereum can compute
    ///      before the first message. Starknet cannot: its address derivation is a
    ///      Pedersen hash chain that the EVM cannot run at any price. So the destination
    ///      creates the receiver, learns the address, and sends it back here.
    ///
    ///      The registry grades it, not this contract. The result is `Attested` — worth
    ///      exactly the security of the bridge that carried it — and readers have to ask
    ///      for that grade explicitly.
    ///
    ///      Hub-only, and that is the whole architecture in one function: the spoke sends
    ///      this message, the hub records it. A spoke has nowhere to record anything to.
    ///
    ///      Self-call only, so it is reachable from `_onInbound` and nowhere else.
    ///
    /// @dev THE SLOT IS DERIVED FROM THE AUTHENTICATED PAIR, WHICH IS WHY NO REQUEST ID IS
    ///      NEEDED. `chainKey` came from `_authenticateOrigin` and `transmitter` is stated
    ///      in the report, so the destination cannot choose which slot it writes. The
    ///      registry then refuses a second write to that slot, so a replayed report is a
    ///      no-op rather than a repoint.
    /// @param interop Canonical ERC-7930 bytes for the receiver on the destination.
    function onDestinationReceiver(
        bytes32 chainKey,
        address transmitter,
        bytes calldata interop
    ) external {
        require(msg.sender == address(this));
        if (address(chainRegistry) == address(0)) revert NoChainRegistry();
        if (transmitter == address(0)) revert ZeroTransmitterCommit();

        bytes32 slot = chainRegistry.receiverSlot(chainKey, transmitter);
        chainRegistry.onForeignRefResolved(slot, interop, "");
        emit DestinationReceiverReported(chainKey, transmitter, slot);
    }

    /// @notice Where `transmitter`'s receiver lives on `chainKey`, at this transceiver's
    ///         provenance bar.
    function destinationReceiverOn(bytes32 chainKey, address transmitter)
        external
        view
        returns (bytes memory)
    {
        if (address(chainRegistry) == address(0)) revert NoChainRegistry();
        return chainRegistry.destinationReceiverOf(
            chainKey, transmitter, minCounterpartProvenance
        );
    }
}
