// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {Provenance} from "src/registry/ForeignRef.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Call} from "src/messaging/Call.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";

/// @notice What a hub needs from the transmitter logic it arms an account with.
interface ITransmitterInit {
    function initialize(address owner, address transceiver, bytes32 salt) external;
}

/// @notice The one thing a hub tells an account after creating it.
/// @dev DELIBERATELY ONE FUNCTION WIDE. A transceiver holds no standing authority over an
///      account, and this is the single exception: the account cannot learn its own receiver
///      address on a chain whose derivation this one cannot run, and the hub is the only
///      contract that authenticates the message carrying it.
interface IAccountReceiverReport {
    function onDestinationReceiverReported(bytes32 chainKey, bytes calldata receiver)
        external;
}

/// @title HubTransceiverBase
/// @notice The home side. One transceiver, N counterparts, one registry to tell them apart.
///
/// @dev WHY THE REGISTRY IS ONLY EVER HERE. The fan-out is one-directional: the hub talks to
///      every destination, and every destination talks only back to the hub. A directory is
///      what you need to hold N claims about where remote code lives and how much each claim
///      is worth; a spoke holds one, is told it at initialization, and would gain nothing
///      from the machinery but a mutable pointer to be compromised. So `chainRegistry`,
///      `messageProvider`, and the provenance dial are absent from the spoke entirely.
///
/// @dev THE HUB IS THE ONLY THING THAT GRADES. `minCounterpartProvenance` is a statement
///      about how much trust to place in a claim about a remote address: a question that
///      only arises when the address was learned rather than known.
abstract contract HubTransceiverBase is TransceiverBase {
    /// The transmitter logic every account on this chain is armed with.
    ///
    /// @dev WRITE-ONCE, BECAUSE CHANGING IT FORKS THE POPULATION. An account's proxy locks
    ///      the moment it is armed, so a change moves nobody who already has one: it only
    ///      affects owners who have not created theirs yet, splitting users into two logic
    ///      versions distinguishable only by when each arrived.
    address public transmitterImplementation;

    event TransmitterImplementationSet(address implementation);

    /// The registry this transceiver asks where its counterparts live.
    IChainRegistryRefs public chainRegistry;
    /// keccak256 of this transceiver's message provider name, e.g. "layerzero".
    bytes32 public messageProvider;
    /// The weakest counterpart provenance this transceiver will send to.
    /// @dev A parity-chain counterpart is `Derived`: same CREATE2 address, recomputed here,
    ///      no bridge trust. Chains where that breaks (Solana, Sui, Aptos, Starknet, and
    ///      zkSync and Tron, whose CREATE2 formulas differ) can only reach `Committed` or
    ///      `Attested`, so this dial decides whether this transceiver talks to them at all.
    Provenance public minCounterpartProvenance;

    event DestinationReceiverReported(
        bytes32 indexed chainKey, address indexed owner, bytes32 salt, address account
    );
    event RoutingSet(
        address chainRegistry, bytes32 messageProvider, Provenance minCounterpartProvenance
    );

    error NoChainRegistry();
    /// @dev The route resolved to a known chain, but the sender is not that chain's
    ///      counterpart, so either the wrong contract spoke, or the registry is stale.
    error NotCounterpart(bytes32 chainKey);
    /// @dev A chain reported an address that says it lives somewhere else.
    error ReportedChainMismatch(bytes32 authenticated, bytes32 reported);
    /// @dev A chain whose addresses this contract can recompute tried to report one. The
    ///      derivation is stronger than the claim, so the claim is refused rather than
    ///      allowed to replace it.
    error ChainDoesNotReport(bytes32 chainKey);

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
    /// @dev A HUB INSTALLS A TRANSMITTER: the only difference from the spoke, and
    ///      deliberately the only one.
    function _accountImplementation() internal view virtual override returns (address) {
        return transmitterImplementation;
    }

    /// @inheritdoc TransceiverBase
    /// @dev A transmitter takes no payload at creation: its owner drives it directly and can
    ///      `execute` whenever it likes, so there is nothing a bootstrap payload would be for
    ///      on this side.
    /// @dev THE SALT IS PASSED BACK IN, because an account cannot recover its own salt from
    ///      its address and `bootstrap` has to state it.
    function _accountInitializer(address owner, bytes32 salt, Call[] memory)
        internal
        view
        virtual
        override
        returns (bytes memory)
    {
        return abi.encodeCall(ITransmitterInit.initialize, (owner, address(this), salt));
    }

    /// @notice Create the caller's transmitter.
    ///
    /// @dev THE OWNER IS `msg.sender` BY CONSTRUCTION, NOT BY ARGUMENT. An owner passed in
    ///      could be anyone, and the derivation only means something if the party it names is
    ///      the party that asked for it. That binding is what stops one party squatting the
    ///      address another intends to use, on every chain at once rather than just here.
    ///
    /// @param salt Chosen by the caller. `bytes32(0)` is a perfectly good default for an
    ///        owner who wants exactly one account.
    /// @return account The transmitter, at the same address its receivers will occupy
    ///         everywhere else.
    function createTransmitter(bytes32 salt) external returns (address account) {
        account = _createCrossAccount(msg.sender, salt, new Call[](0));
    }

    /// @notice Where `(owner, salt)`'s transmitter lives, before it exists.
    ///
    /// @dev An owner can compute the address they are about to claim, here and on every
    ///      parity chain, before spending anything. It is also what lets an address be pinned
    ///      inside a payload approved before the account exists.
    function predictTransmitter(address owner, bytes32 salt)
        external
        view
        returns (address)
    {
        return predictCrossAccount(owner, salt);
    }

    /// @notice Point this transceiver at the registry, and state its provenance bar.
    function setRouting(
        IChainRegistryRefs chainRegistry_,
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

    /// @inheritdoc OutboundBase
    /// @dev The provenance bar is applied here, inside the registry read, rather than by
    ///      the caller: `transceiverFor` refuses anything below it.
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
    /// @dev N ORIGINS, SO IT IS A LOOKUP. The route names the chain and the registry names
    ///      that chain's counterpart at this transceiver's provenance bar, so a hub whose bar
    ///      is `Derived` will not accept a message from a chain whose counterpart is only
    ///      `Attested`, however well-formed the message is. Both halves must agree: an
    ///      unknown route reverts in `chainKeyOfRoute`, a wrong sender reverts here.
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
    ///      way, because transmitters live on the home chain.
    function _handleInbound(bytes32 chainKey, bytes calldata message) internal override {
        (address owner, bytes32 salt, bytes memory interop) =
            Envelope.decodeReceiverReport(message);
        this.onDestinationReceiver(chainKey, owner, salt, interop);
    }

    /// @notice Turn an inbound source id back into a chain.
    /// @dev The reverse of `_routeTo`, answered from the same write-once table, because two
    ///      tables would drift.
    function _chainKeyOf(bytes memory route) internal view returns (bytes32) {
        return chainKeyOfRoute(route);
    }

    /// @notice Inbound callback: the destination reports where it created the receiver.
    ///
    /// @dev THE ESCAPE HATCH FOR UNDERIVABLE CHAINS. Most destinations need nothing like it,
    ///      because the hub can compute a parity chain's receiver address before the first
    ///      message. Starknet cannot: its derivation is a Pedersen hash chain the EVM cannot
    ///      run at any price, and zkSync and Tron simply use different CREATE2 formulas. So
    ///      the destination creates the receiver, learns the address, and sends it back.
    ///      Hub-only, which is the whole architecture in one function: the spoke sends, the
    ///      hub records, and a spoke has nowhere to record anything to. Self-call only, so
    ///      it is reachable from `_onInbound` and nowhere else.
    ///
    /// @dev IT WRITES TO THE ACCOUNT, NOT TO THE REGISTRY, and that is what makes the report
    ///      worth sending. The address used to be filed under a registry slot that nothing
    ///      on the send path reads, because the registry is deliberately out of that path:
    ///      a chain whose receiver could not be derived stayed unreachable no matter how
    ///      faithfully its address was recorded. The transmitter is the contract that
    ///      addresses that receiver, so it is the contract that is told.
    ///
    /// @dev THE REGISTRY STILL SAYS WHICH CHAINS MAY REPORT, which is the part that IS
    ///      directory data. `requiresReceiverCallback` is true exactly where this contract
    ///      cannot recompute an address, so a report from a chain the hub can derive itself
    ///      is refused: it would either restate a `Derived` fact or replace it with a
    ///      weaker one, and neither is something a remote chain gets to do.
    ///
    /// @dev THE DESTINATION CANNOT CHOOSE WHICH ACCOUNT IT WRITES, WHICH IS WHY NO REQUEST
    ///      ID IS NEEDED. `chainKey` came from `_authenticateOrigin` and `(owner, salt)` is
    ///      stated in the report, so the account is `predictCrossAccount` of the stated
    ///      pair: the same derivation `bootstrap` proved the caller against. The account
    ///      then refuses a second report itself.
    ///
    /// @dev THE REPORTED ADDRESS MUST BE ON THE CHAIN THAT REPORTED IT, so a stored
    ///      counterpart cannot contradict its own envelope. It buys an attacker nothing on
    ///      its own, since an authenticated spoke can already report a wrong address on its
    ///      own chain, and that remains the residual risk: the owner's
    ///      `setDestinationReceiver` is the recovery.
    /// @param interop Canonical ERC-7930 bytes for the receiver on the destination.
    function onDestinationReceiver(
        bytes32 chainKey,
        address owner,
        bytes32 salt,
        bytes calldata interop
    ) external {
        require(msg.sender == address(this));
        if (address(chainRegistry) == address(0)) revert NoChainRegistry();
        if (owner == address(0)) revert ZeroOwner();
        if (!chainRegistry.requiresReceiverCallback(chainKey)) {
            revert ChainDoesNotReport(chainKey);
        }

        bytes32 reported = Erc7930.chainKey(interop);
        if (reported != chainKey) revert ReportedChainMismatch(chainKey, reported);

        address account = predictCrossAccount(owner, salt);
        IAccountReceiverReport(account).onDestinationReceiverReported(
            chainKey, Erc7930.parseStrict(interop).addr
        );
        emit DestinationReceiverReported(chainKey, owner, salt, account);
    }

    /// @notice Where an account's receiver lives on `chainKey`, as that account records it.
    /// @dev A passthrough, kept because an operator reading the hub should not have to know
    ///      that the answer moved. It is the account's own counterpart table, which is also
    ///      what its `sendMessage` checks against, so there is one answer rather than a
    ///      directory copy that could disagree with the send path.
    function destinationReceiverOn(bytes32 chainKey, address owner, bytes32 salt)
        external
        view
        returns (bytes memory)
    {
        return TransmitterBase(payable(predictCrossAccount(owner, salt))).counterpartOn(
            chainKey
        );
    }
}
