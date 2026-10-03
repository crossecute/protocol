// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
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
/// @dev The single exception to a transceiver having no authority over an account: the
///      account cannot learn its receiver's address on a chain this one cannot derive, and
///      only the hub authenticates the message carrying it.
interface IAccountReceiverReport {
    function onDestinationReceiverReported(bytes32 chainKey, bytes calldata receiver) external;
}

/// @title HubTransceiverBase
/// @notice The home side. One transceiver, N counterparts, one registry to tell them apart.
///
/// @dev Only the hub has a registry, a provider id, and a provenance bar: it holds N claims
///      about where remote code lives and how much each is worth, while a spoke is told its
///      one counterpart at initialization.
abstract contract HubTransceiverBase is TransceiverBase, OwnableUpgradeable {
    /// The transmitter logic every account on this chain is armed with.
    /// @dev Write-once: accounts lock when armed, so a change would split them into two logic
    ///      versions by creation time.
    address public transmitterImplementation;

    event TransmitterImplementationSet(address implementation);

    /// The registry this transceiver reads provenance and derivations from.
    IChainRegistryRefs public chainRegistry;
    /// keccak256 of this transceiver's message provider name, e.g. "layerzero".
    bytes32 public messageProvider;
    /// The weakest counterpart provenance this transceiver will send to.
    /// @dev A parity-chain counterpart is `Derived`. Solana, Sui, Aptos, Starknet, zkSync, and
    ///      Tron reach only `Attested`, so this decides whether the hub talks to them at all.
    Provenance public minCounterpartProvenance;

    event DestinationReceiverReported(bytes32 indexed chainKey, address indexed owner, bytes32 salt, address account);
    event RoutingSet(address chainRegistry, bytes32 messageProvider, Provenance minCounterpartProvenance);

    error NoChainRegistry();
    /// @dev The route resolved to a known chain, but the sender is not its counterpart.
    error NotCounterpart(bytes32 chainKey);
    /// @dev The chain's grade is below this transceiver's bar, so it will not send there.
    error InsufficientCounterpartProvenance(bytes32 chainKey, Provenance grade);
    /// @dev Re-pointing a counterpart would redirect the destination; moving one is a redeploy.
    error CounterpartAlreadySet(bytes32 chainKey);
    /// @dev The derivation inputs are not the ones this transaction approved. See
    ///      `resolveCounterpart`.
    error ParamsCommitmentMismatch(bytes32 chainKey);
    /// @dev A chain reported an address that says it lives somewhere else.
    error ReportedChainMismatch(bytes32 authenticated, bytes32 reported);
    /// @dev A chain whose addresses this contract can recompute tried to report one; the
    ///      derivation outranks the claim.
    error ChainDoesNotReport(bytes32 chainKey);
    /// @dev The registry or provider id is already set to a different value. See `setRouting`.
    error RoutingAlreadySet();

    /// @param owner_ The configuring authority: it adds destinations and prices bootstraps,
    ///        and can move no money. `Ownable` refuses a zero, which would leave a sealed hub
    ///        that can never be given a route.
    /// @param treasury_ Where bootstrap fees go, the moment they are charged. Write-once. Zero
    ///        means this hub charges nothing, and `setBootstrapFee` then refuses a non-zero fee.
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
    function _accountImplementation() internal view virtual override returns (address) {
        return transmitterImplementation;
    }

    /// @inheritdoc TransceiverBase
    /// @dev A transmitter takes no creation payload: its owner drives it directly. The salt is
    ///      passed in because an account cannot recover it from its own address.
    function _accountInitializer(address owner, bytes32 salt, address, Call[] memory)
        internal
        view
        virtual
        override
        returns (bytes memory)
    {
        return abi.encodeCall(ITransmitterInit.initialize, (owner, address(this), salt));
    }

    /// @notice Create the caller's transmitter.
    /// @dev The owner is `msg.sender`, never an argument, so no one can claim the address
    ///      another party will occupy on every chain.
    /// @param salt Chosen by the caller; `bytes32(0)` suits an owner who wants one account.
    /// @return account The transmitter, at the address its receivers occupy on parity chains.
    function createTransmitter(bytes32 salt) external returns (address account) {
        account = _createCrossAccount(msg.sender, salt, localChainKey, address(0), new Call[](0));
    }

    /// @notice Where `(owner, salt)`'s transmitter lives, before it exists.
    function predictTransmitter(address owner, bytes32 salt) external view returns (address) {
        return predictCrossAccount(owner, salt, localChainKey);
    }

    /// @notice Teach this hub how a destination is named. Write-once, and the owner's.
    /// @dev Hub-only because only a hub adds destinations; a spoke's one route is written in
    ///      its initializer. A binding wraps this only where it keeps a provider-native id.
    function setRoute(bytes32 chainKey, bytes memory route) public onlyOwner {
        _setRoute(chainKey, route);
    }

    /// @notice Point this transceiver at the registry, name its provider id, and set its
    ///         provenance bar.
    ///
    /// @dev The registry and provider id are write-once, like routes and counterparts:
    ///      repointing either would redirect every future lookup. The same pair again is a
    ///      no-op; a different one reverts `RoutingAlreadySet`.
    ///
    /// @dev `minCounterpartProvenance` stays rebindable and is written on every call: it is
    ///      how the owner reacts to a bridge's standing changing without a redeploy.
    function setRouting(
        IChainRegistryRefs chainRegistry_,
        bytes32 messageProvider_,
        Provenance minCounterpartProvenance_
    ) external onlyOwner {
        if (address(chainRegistry) != address(0)) {
            if (chainRegistry != chainRegistry_ || messageProvider != messageProvider_) {
                revert RoutingAlreadySet();
            }
        } else {
            chainRegistry = chainRegistry_;
            messageProvider = messageProvider_;
        }

        minCounterpartProvenance = minCounterpartProvenance_;
        emit RoutingSet(address(chainRegistry_), messageProvider_, minCounterpartProvenance_);
    }

    /* ============================== the bootstrap fee ========================== */

    /// chainKey => what standing an account up there costs, on top of the message fee.
    ///
    /// @dev Pays for the return leg on a chain that has one: a diverging spoke reports each
    ///      account home from its own balance. The account being created pays, once.
    ///
    /// @dev The fee is forwarded to `treasury` in the home currency; the spoke needs the
    ///      destination's, so spokes are funded out of band. Zero by
    ///      default, so parity destinations, which never report, pay nothing.
    mapping(bytes32 => uint256) public bootstrapFee;

    /// @notice Where a bootstrap fee goes, the moment it is charged.
    /// @dev An address rather than a role: the fee moves in the transaction that charges it,
    ///      so there is no balance to direct. Hub-only, since fees are charged at bootstrap on
    ///      the home chain. Write-once, so a compromised owner cannot redirect future fees.
    address public treasury;

    event BootstrapFeeSet(bytes32 indexed chainKey, uint256 fee);
    event BootstrapFeePaid(bytes32 indexed chainKey, address indexed to, uint256 amount);

    /// @dev The caller sent less than the destination's fee.
    error InsufficientBootstrapFee(uint256 required, uint256 provided);
    /// @dev A fee cannot be charged with nowhere to send it; refused when set.
    error NoTreasury();
    error FeeTransferFailed(address to, uint256 amount);

    /// @notice Set what standing an account up on `chainKey` costs.
    /// @dev Rebindable: a price redirects nothing. A non-zero fee needs a treasury, refused
    ///      here rather than inside a bootstrap that would burn it.
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
    /// @dev Takes the fee off the top, forwards it, and returns what is left for the send.
    ///      Paid before the send, which reaches a provider endpoint and arbitrary code beyond
    ///      it; a later revert unwinds the payment too. `call` rather than `transfer`, so a
    ///      treasury contract is not held to the 2300-gas stipend.
    function _bootstrapSendValue(bytes32 chainKey) internal override returns (uint256) {
        uint256 fee = bootstrapFee[chainKey];
        if (msg.value < fee) revert InsufficientBootstrapFee(fee, msg.value);
        if (fee == 0) return msg.value;

        address to = treasury;
        emit BootstrapFeePaid(chainKey, to, fee);

        // forge-lint: disable-next-line(arbitrary-send-eth) the write-once treasury
        (bool ok,) = to.call{value: fee}("");
        if (!ok) revert FeeTransferFailed(to, fee);
        return msg.value - fee;
    }

    /* ========================= the counterpart directory ======================= */

    /// @notice Record where this provider's transceiver sits on a destination chain.
    ///
    /// @dev Held by the hub, not the registry, because a location is per (chain, provider)
    ///      and the hub is that pair. The registry holds what is common to every provider:
    ///      `provenanceFor(chainKey)`.
    ///
    /// @dev Write-once: re-pointing a counterpart redirects the destination.
    /// @param interop Canonical ERC-7930 bytes, so the registry can check it is well-formed
    ///        and on `chainKey`. The address half is stored, since inbound senders are
    ///        compared to it.
    function setCounterpart(bytes32 chainKey, bytes calldata interop) external onlyOwner {
        if (address(chainRegistry) == address(0)) revert NoChainRegistry();
        if (hasCounterpart(chainKey)) revert CounterpartAlreadySet(chainKey);

        chainRegistry.validateLocation(chainKey, interop);
        _setCounterpart(chainKey, Erc7930.parseStrict(interop).addr);
    }

    /// @notice Record the counterpart by recomputing it from the registry's deriver and inputs
    ///         for that chain, rather than by being told.
    /// @dev The inputs were written in an earlier transaction, so `paramsCommitment` puts
    ///      their hash in this one's signed calldata: the signers approve the inputs, not a
    ///      pointer to them.
    /// @param paramsCommitment `keccak256(chainRegistry.deriveParams(chainKey))`.
    function resolveCounterpart(bytes32 chainKey, bytes32 paramsCommitment) external onlyOwner {
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
    /// @dev A Move call target is `address::module::function`, so the address alone does not
    ///      identify it. Declared, not derived, so it carries the chain's grade.
    mapping(bytes32 => bytes) private _qualifiers;

    event QualifierSet(bytes32 indexed chainKey, bytes32 qualifierHash);

    error NoQualifier(bytes32 chainKey);
    error QualifierMismatch(bytes32 chainKey);

    /// @notice Attach a qualified name to a counterpart on a Move chain.
    /// @dev The same qualifier again is a no-op; a different one reverts, since re-pointing a
    ///      call target is re-pointing the counterpart.
    function setQualifier(bytes32 chainKey, Move.MoveQualifier calldata q) external onlyOwner {
        if (!hasCounterpart(chainKey)) revert NoCounterpartFor(chainKey);
        if (address(chainRegistry) == address(0)) revert NoChainRegistry();
        Move.validate(q, Erc7930.parseStrict(chainRegistry.chainIdentifier(chainKey)).chainType);

        bytes32 qh = Move.hash(q);
        bytes memory existing = _qualifiers[chainKey];
        if (existing.length != 0 && Move.hash(abi.decode(existing, (Move.MoveQualifier))) != qh) {
            revert QualifierMismatch(chainKey);
        }

        _qualifiers[chainKey] = abi.encode(q);
        emit QualifierSet(chainKey, qh);
    }

    /// @notice The qualified name a destination executor needs to build the call.
    function qualifier(bytes32 chainKey) external view returns (Move.MoveQualifier memory q) {
        bytes memory raw = _qualifiers[chainKey];
        if (raw.length == 0) revert NoQualifier(chainKey);
        q = abi.decode(raw, (Move.MoveQualifier));
    }

    /// @inheritdoc OutboundBase
    ///
    /// @dev Applies the registry's per-chain grade, which every provider's hub reads alike.
    ///
    /// @dev An unset counterpart on a `Derived` chain is this contract's own address: hub and
    ///      spoke proxies are deployed through the same factory at the same salt, so they
    ///      coincide wherever Ethereum's CREATE2 holds.
    function _counterpartOn(bytes32 chainKey) internal view override returns (bytes memory) {
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
    /// @dev The route names the chain; the sender must be that chain's counterpart at this
    ///      hub's provenance bar. An unknown route reverts in `chainKeyOfRoute`.
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
    /// @dev A hub receives receiver reports only; transmitters live on the home chain.
    function _handleInbound(bytes32 chainKey, bytes calldata message) internal virtual override {
        (address owner, bytes32 salt, bytes memory interop) = Envelope.decodeReceiverReport(message);
        _onDestinationReceiver(chainKey, owner, salt, interop);
    }

    /// @notice Turn an inbound source id back into a chain, from the write-once route table.
    function _chainKeyOf(bytes memory route) internal view returns (bytes32) {
        return chainKeyOfRoute(route);
    }

    /// @notice The destination reports where it created the receiver.
    ///
    /// @dev For chains the hub cannot derive: Starknet's Pedersen derivation, and zkSync's and
    ///      Tron's CREATE2 formulas. Internal, so reachable only from an authenticated
    ///      `_onInbound`.
    ///
    /// @dev Written to the account, not the registry, because the transmitter is what
    ///      addresses that receiver and the registry is out of the send path. The registry
    ///      still decides which chains may report (`requiresReceiverCallback`), so a chain the
    ///      hub derives cannot replace a `Derived` fact with a reported one.
    ///
    /// @dev The destination cannot choose the account: `chainKey` is authenticated and the
    ///      account is `predictCrossAccount` of the stated pair, the derivation `bootstrap`
    ///      checked the caller against. The account refuses a second report.
    ///
    /// @dev The reported address must be on the reporting chain. An authenticated spoke can
    ///      still report a wrong address on its own chain; the account keeps the first one,
    ///      so a compromised spoke costs only its own chain.
    /// @param interop Canonical ERC-7930 bytes for the receiver on the destination.
    function _onDestinationReceiver(bytes32 chainKey, address owner, bytes32 salt, bytes memory interop) internal {
        if (address(chainRegistry) == address(0)) revert NoChainRegistry();
        if (owner == address(0)) revert ZeroOwner();
        if (!chainRegistry.requiresReceiverCallback(chainKey)) {
            revert ChainDoesNotReport(chainKey);
        }

        bytes32 reported = Erc7930.chainKey(interop);
        if (reported != chainKey) revert ReportedChainMismatch(chainKey, reported);

        address account = predictCrossAccount(owner, salt, localChainKey);
        IAccountReceiverReport(account).onDestinationReceiverReported(chainKey, Erc7930.parseStrict(interop).addr);
        emit DestinationReceiverReported(chainKey, owner, salt, account);
    }

    /// @notice Whether `chainKey` reports its receiver address back, rather than this hub
    ///         deriving it.
    /// @dev True exactly where this contract cannot recompute an address (zkSync, Tron, every
    ///      non-EVM VM), from the same registry answer `_onDestinationReceiver` enforces. A hub
    ///      with no registry answers false; `_requireRoutable` then refuses the bootstrap.
    function reportsReceiver(bytes32 chainKey) public view override returns (bool) {
        if (address(chainRegistry) == address(0)) return false;
        return chainRegistry.requiresReceiverCallback(chainKey);
    }

    /// @notice Where an account's receiver lives on `chainKey`, as that account records it.
    /// @dev Reads the account's own counterpart table, the one its `sendMessage` checks.
    function destinationReceiverOn(bytes32 chainKey, address owner, bytes32 salt) external view returns (bytes memory) {
        return TransmitterBase(payable(predictCrossAccount(owner, salt, localChainKey))).counterpartOn(chainKey);
    }
}
