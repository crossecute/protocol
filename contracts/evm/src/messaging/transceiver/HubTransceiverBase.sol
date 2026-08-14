// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Move} from "src/addressing/Move.sol";
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
abstract contract HubTransceiverBase is TransceiverBase, OwnableUpgradeable {
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
    ///      zkSync and Tron, whose CREATE2 formulas differ) can only reach `Attested`, so
    ///      this dial decides whether this transceiver talks to them at all.
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
    /// @dev The chain's grade is below this transceiver's bar, so it will not send there.
    error InsufficientCounterpartProvenance(bytes32 chainKey, Provenance grade);
    /// @dev A counterpart names the contract every message to that chain authenticates
    ///      against, so re-pointing one redirects the destination. It is a redeploy.
    error CounterpartAlreadySet(bytes32 chainKey);
    /// @dev The derivation inputs are not the ones this transaction approved. See
    ///      `resolveCounterpart`.
    error ParamsCommitmentMismatch(bytes32 chainKey);
    /// @dev A chain reported an address that says it lives somewhere else.
    error ReportedChainMismatch(bytes32 authenticated, bytes32 reported);
    /// @dev A chain whose addresses this contract can recompute tried to report one. The
    ///      derivation is stronger than the claim, so the claim is refused rather than
    ///      allowed to replace it.
    error ChainDoesNotReport(bytes32 chainKey);

    /// @param owner_ The configuring authority, and the only live one in the protocol: it adds
    ///        destinations and prices bootstraps, and can move no money at all. `Ownable`
    ///        refuses a zero, since a hub with no owner could never be given a route and would
    ///        deploy, seal itself, and be unusable, with the failure arriving one transaction
    ///        later than the mistake. A SPOKE TAKES NO SUCH ARGUMENT, because it has nothing
    ///        for one to do.
    /// @param treasury_ Where bootstrap fees go, the moment they are charged. Write-once,
    ///        and the only one in the protocol: fees are charged here, on the home chain, in
    ///        the home chain's currency. A zero one is allowed and means this hub charges
    ///        nothing — `setBootstrapFee` then refuses a non-zero fee, so a fee can never be
    ///        taken with nowhere to send it.
    function __HubTransceiverBase_init(
        address owner_,
        address treasury_,
        address[] memory gateways,
        address transmitterImplementation_
    ) internal onlyInitializing {
        __Ownable_init(owner_);

        treasury = treasury_;

        if (transmitterImplementation_ == address(0)) revert NoAccountImplementation();
        transmitterImplementation = transmitterImplementation_;
        emit TransmitterImplementationSet(transmitterImplementation_);

        // Last, and the hub is sealed. See `TransceiverBase.__TransceiverBase_init`.
        __TransceiverBase_init(gateways);
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

    /// @notice Teach this hub how a destination is named. WRITE-ONCE, and the msig's.
    ///
    /// @dev IT IS ON THE HUB RATHER THAN THE SHARED BASE, because adding a destination is
    ///      something only a hub ever does: it fans out to N chains and learns them over time,
    ///      while a spoke knows exactly one route — its home — written in its initializer with
    ///      no setter. A public setter on the base would have given a spoke an entry point
    ///      whose every argument it refuses anyway, since `_routeTo` reverts `NotHome` for
    ///      anything else.
    ///
    /// @dev The table, the reverse index, and the reads all live on `OutboundBase`, which is
    ///      what a sender needs to address anything. This is only the authority over it: a
    ///      binding wraps this in a typed setter where it keeps a provider-native value of its
    ///      own, and a gateway binding adds nothing.
    function setRoute(bytes32 chainKey, bytes memory route) public onlyOwner {
        _setRoute(chainKey, route);
    }

    /// @notice Point this transceiver at the registry, and state its provenance bar.
    function setRouting(
        IChainRegistryRefs chainRegistry_,
        bytes32 messageProvider_,
        Provenance minCounterpartProvenance_
    ) external onlyOwner {
        chainRegistry = chainRegistry_;
        messageProvider = messageProvider_;
        minCounterpartProvenance = minCounterpartProvenance_;
        emit RoutingSet(
            address(chainRegistry_), messageProvider_, minCounterpartProvenance_
        );
    }

    /* ============================== the bootstrap fee ========================== */

    /// chainKey => what standing an account up there costs, on top of the message fee.
    ///
    /// @dev IT PAYS FOR THE RETURN LEG ON A CHAIN THAT HAS ONE. A spoke whose addresses
    ///      diverge reports each account home from its OWN balance, because the send is
    ///      nested inside a delivery callback where `msg.value` is zero, so somebody has to
    ///      keep that spoke funded and a dry one fails every bootstrap on its chain. This is
    ///      that somebody, made systematic: the account being stood up pays, once, at the
    ///      moment it creates the obligation.
    ///
    /// @dev IT IS NOT A BRIDGE FOR THE MONEY, AND CANNOT BE. The fee accrues here, in the
    ///      home chain's currency; the spoke needs the DESTINATION's currency on the
    ///      destination. Nothing on-chain connects the two, so the msig withdraws and funds
    ///      spokes out of band. What this buys is that the funding is recovered from the
    ///      accounts that cause it rather than subsidised indefinitely, which is the
    ///      difference between an operational cost and an operational surprise.
    ///
    /// @dev PER CHAIN, AND ZERO BY DEFAULT, so a parity destination pays nothing. Those
    ///      chains send no report and create no obligation, and charging them would be a
    ///      tax on the common case to fund the rare one.
    mapping(bytes32 => uint256) public bootstrapFee;

    /// @notice Where a bootstrap fee goes, the moment it is charged. ONE ADDRESS, NAMED AT
    ///         DEPLOYMENT, FOR THE WHOLE PROTOCOL.
    ///
    /// @dev A SINGLE ADDRESS RATHER THAN A ROLE, because a role answers "may this address be
    ///      paid" and the question here is "where does this go". Nothing chooses between
    ///      several destinations any more: the fee moves in the same transaction that charges
    ///      it, so there is no held balance for a caller to direct and no `withdrawFees` to
    ///      gate. The role bought a bound on an operation that no longer exists.
    ///
    /// @dev ON THE HUB ONLY, AND THERE IS ONLY ONE HUB. Fees are charged at bootstrap, which
    ///      happens on the home chain in the home chain's currency; a spoke charges nothing
    ///      and holds nothing to withdraw, so a treasury there would be an address with no
    ///      purpose and a key worth stealing. One treasury, one chain, one address.
    ///
    /// @dev WRITE-ONCE, LIKE EVERYTHING ELSE A DEPLOYMENT NAMES. A settable one would let a
    ///      compromised owner redirect every future fee in a single transaction, which is
    ///      exactly what routing the money straight through is meant to make impossible.
    address public treasury;

    event BootstrapFeeSet(bytes32 indexed chainKey, uint256 fee);
    /// @dev Emitted where the money actually moves, which is now inside the bootstrap that
    ///      caused it rather than in a later withdrawal.
    event BootstrapFeePaid(bytes32 indexed chainKey, address indexed to, uint256 amount);

    /// @dev The caller sent less than the destination's fee, so the message would be
    ///      dispatched with the shortfall taken out of the provider's payment instead.
    error InsufficientBootstrapFee(uint256 required, uint256 provided);
    /// @dev A fee cannot be charged with nowhere to send it. Refused when it is SET rather
    ///      than when it is charged, so the mistake surfaces at configuration time.
    error NoTreasury();
    error FeeTransferFailed(address to, uint256 amount);

    /// @notice Set what standing an account up on `chainKey` costs.
    /// @dev REBINDABLE, unlike a route or a counterpart. It redirects nothing and points at
    ///      nothing; it is a price, and a price that could not be corrected would be the
    ///      only value here that has to be right first time for a reason nobody can state.
    /// @dev A NON-ZERO FEE NEEDS A TREASURY, and this is where that is refused: charging with
    ///      nowhere to send it would burn the fee inside the bootstrap that paid it, one
    ///      transaction after the mistake and with nothing to recover.
    function setBootstrapFee(bytes32 chainKey, uint256 fee) external onlyOwner {
        if (fee != 0 && treasury == address(0)) revert NoTreasury();
        bootstrapFee[chainKey] = fee;
        emit BootstrapFeeSet(chainKey, fee);
    }

    /// @inheritdoc TransceiverBase
    function _bootstrapSurcharge(bytes32 chainKey) internal view override returns (uint256) {
        return bootstrapFee[chainKey];
    }

    /// @inheritdoc TransceiverBase
    /// @dev TAKE THE FEE OFF THE TOP, FORWARD IT, AND HAND THE BINDING WHAT IS LEFT. It used
    ///      to accrue here against a later `withdrawFees`, which meant a balance sitting on
    ///      the contract that authenticates every inbound message, an owner-gated operation
    ///      to move it, and a role to bound where it could go. Paying the treasury in the same
    ///      transaction removes all three: nothing accumulates, so nothing can be redirected,
    ///      swept, or confused with a provider's refund.
    ///
    /// @dev IT MOVES BEFORE THE SEND, which is the same ordering the bootstrap flag uses and
    ///      for the same reason: the dispatch that follows reaches a provider endpoint and,
    ///      through it, arbitrary code. Paying afterwards would leave the fee's fate depending
    ///      on what that code did. If anything below reverts, the whole transaction unwinds
    ///      and the payment goes with it.
    ///
    /// @dev THE TREASURY IS OURS AND STILL GETS A `call`, not a `transfer`: the 2300-gas
    ///      stipend is not survivable by a contract that does anything on receipt, and a
    ///      failure here must be loud rather than silently under-paying the provider.
    function _bootstrapSendValue(bytes32 chainKey)
        internal
        override
        returns (uint256)
    {
        uint256 fee = bootstrapFee[chainKey];
        if (msg.value < fee) revert InsufficientBootstrapFee(fee, msg.value);
        if (fee == 0) return msg.value;

        address to = treasury;
        (bool ok,) = to.call{value: fee}("");
        if (!ok) revert FeeTransferFailed(to, fee);

        emit BootstrapFeePaid(chainKey, to, fee);
        return msg.value - fee;
    }

    /* ========================= the counterpart directory ======================= */

    /// @notice Record where this provider's transceiver sits on a destination chain.
    ///
    /// @dev THE HUB HOLDS THIS, NOT THE REGISTRY, BECAUSE IT IS PER PROVIDER. Two providers
    ///      deploy two transceivers to the same chain, so a location is a fact about a
    ///      (chain, provider) pair and the hub IS that pair. What stays in the registry is
    ///      the part that is the same for everyone: `provenanceFor(chainKey)`, how much any
    ///      address claim about that chain is worth.
    ///
    /// @dev WRITE-ONCE, LIKE A ROUTE. A counterpart names the contract every message to that
    ///      chain authenticates against, so re-pointing one redirects the whole destination
    ///      at once. Moving it is a redeploy.
    /// @param interop Canonical ERC-7930 bytes for the counterpart, so the registry can
    ///        check it is well-formed AND on the chain it is being filed under. The address
    ///        half is what gets stored, since that is what an inbound sender is compared to.
    function setCounterpart(bytes32 chainKey, bytes calldata interop) external onlyOwner {
        if (address(chainRegistry) == address(0)) revert NoChainRegistry();
        if (hasCounterpart(chainKey)) revert CounterpartAlreadySet(chainKey);

        chainRegistry.validateLocation(chainKey, interop);
        _setCounterpart(chainKey, Erc7930.parseStrict(interop).addr);
    }

    /// @notice Record it by recomputing it, rather than by being told.
    ///
    /// @dev THIS IS WHAT `Derived` MEANS, AND IT IS THE REASON TO PREFER IT. The registry
    ///      holds the deriver and the inputs for that chain, and `expectedTransceiver`
    ///      recomputes the address from them right now; nothing is taken on faith and no
    ///      message is involved. The alternative above is a declaration, and on a chain the
    ///      registry grades below `Derived` it is the only option there is.
    ///
    /// @dev `paramsCommitment` IS NOT CEREMONY. The derivation inputs were written to the
    ///      registry in an EARLIER transaction, so without it the signers approving THIS one
    ///      would be approving a POINTER rather than the inputs, and `Derived` claims
    ///      precisely that the inputs were approved. Passing the hash puts the exact bytes
    ///      in the signed calldata and keeps the grade honest.
    /// @param paramsCommitment `keccak256(chainRegistry.deriveParams(chainKey))`.
    function resolveCounterpart(bytes32 chainKey, bytes32 paramsCommitment)
        external
        onlyOwner
    {
        if (address(chainRegistry) == address(0)) revert NoChainRegistry();
        if (hasCounterpart(chainKey)) revert CounterpartAlreadySet(chainKey);
        if (keccak256(chainRegistry.deriveParams(chainKey)) != paramsCommitment) {
            revert ParamsCommitmentMismatch(chainKey);
        }

        bytes memory interop = chainRegistry.expectedTransceiver(chainKey);
        chainRegistry.validateLocation(chainKey, interop);
        _setCounterpart(chainKey, Erc7930.parseStrict(interop).addr);
    }

    /// chainKey => abi-encoded `Move.MoveQualifier` for the counterpart there.
    ///
    /// @dev IT FOLLOWS THE COUNTERPART, because it qualifies one: a Move call target is
    ///      `address::module::function`, and the address alone does not identify it. It is a
    ///      DECLARATION rather than a derived value, since nothing here could recompute
    ///      `transceiver::receive_message` from an address, so it carries no grade of its own
    ///      and inherits the chain's.
    mapping(bytes32 => bytes) private _qualifiers;

    event QualifierSet(bytes32 indexed chainKey, bytes32 qualifierHash);

    error NoQualifier(bytes32 chainKey);
    error QualifierMismatch(bytes32 chainKey);

    /// @notice Attach a qualified name to a counterpart on a Move chain.
    /// @dev Re-setting the SAME qualifier is a no-op; a DIFFERENT one reverts, because
    ///      re-pointing a live call target is the same operation as re-pointing the address
    ///      it lives at, and that is a redeploy.
    function setQualifier(bytes32 chainKey, Move.MoveQualifier calldata q)
        external
        onlyOwner
    {
        if (!hasCounterpart(chainKey)) revert NoCounterpartFor(chainKey);
        if (address(chainRegistry) == address(0)) revert NoChainRegistry();
        Move.validate(q, Erc7930.parseStrict(chainRegistry.chainIdentifier(chainKey)).chainType);

        bytes32 qh = Move.hash(q);
        bytes memory existing = _qualifiers[chainKey];
        if (existing.length != 0 && Move.hash(abi.decode(existing, (Move.MoveQualifier))) != qh)
        {
            revert QualifierMismatch(chainKey);
        }

        _qualifiers[chainKey] = abi.encode(q);
        emit QualifierSet(chainKey, qh);
    }

    /// @notice The qualified name a destination executor needs to build the call.
    function qualifier(bytes32 chainKey)
        external
        view
        returns (Move.MoveQualifier memory q)
    {
        bytes memory raw = _qualifiers[chainKey];
        if (raw.length == 0) revert NoQualifier(chainKey);
        q = abi.decode(raw, (Move.MoveQualifier));
    }

    /// @inheritdoc OutboundBase
    ///
    /// @dev THE BAR IS APPLIED HERE, AGAINST THE REGISTRY'S PER-CHAIN GRADE. The address is
    ///      this contract's; how much it is worth is the chain's, and every provider's hub
    ///      reads the same answer, so two of them cannot disagree about the same chain.
    ///
    /// @dev AN UNSET COUNTERPART FALLS BACK TO THIS CONTRACT'S OWN ADDRESS on a chain the
    ///      registry grades `Derived`. A transceiver is deployed as a proxy through the same
    ///      factory at the same salt, so hub and spoke land together wherever Ethereum's
    ///      CREATE2 formula holds, which is exactly what `Derived` records. That is the
    ///      common case, and requiring a table whose every row said the same thing would
    ///      make a real gap indistinguishable from the default.
    function _counterpartOn(bytes32 chainKey)
        internal
        view
        override
        returns (bytes memory)
    {
        if (address(chainRegistry) == address(0)) revert NoChainRegistry();

        Provenance grade = chainRegistry.provenanceFor(chainKey);
        if (uint8(grade) < uint8(minCounterpartProvenance)) {
            revert InsufficientCounterpartProvenance(chainKey, grade);
        }

        if (!hasCounterpart(chainKey)) {
            if (grade != Provenance.Derived) revert NoCounterpartFor(chainKey);
            return abi.encodePacked(address(this));
        }
        return OutboundBase._counterpartOn(chainKey);
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
    ///      worth sending. The registry is deliberately out of the send path, so an address
    ///      recorded there could not make a diverging chain reachable however faithfully it
    ///      was filed. The transmitter is the contract that addresses that receiver, so it is
    ///      the contract that is told.
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
    ///      own chain. That is the residual risk and it has no recovery: the account pins
    ///      the first report it accepts, so a compromised spoke costs its own chain.
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

    /// @notice Whether `chainKey` reports its receiver address back, rather than this hub
    ///         deriving it.
    ///
    /// @dev THE ACCOUNT ASKS THIS BEFORE IT RECORDS A COUNTERPART, because whether an address
    ///      is knowable in advance is a property of the destination and an account holds no
    ///      registry. True exactly where this contract cannot recompute an address — zkSync,
    ///      Tron, every non-EVM VM — which is the same condition `onDestinationReceiver`
    ///      enforces when a report arrives, read from the same place, so the two cannot
    ///      disagree about which chains speak for themselves.
    ///
    /// @dev A HUB WITH NO REGISTRY ANSWERS FALSE, which is the honest answer rather than a
    ///      revert: no chain has been graded, so no chain reports, and `_requireRoutable`
    ///      refuses the bootstrap that would have depended on it a moment later.
    function reportsReceiver(bytes32 chainKey) public view override returns (bool) {
        if (address(chainRegistry) == address(0)) return false;
        return chainRegistry.requiresReceiverCallback(chainKey);
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
