// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Roles} from "src/messaging/Roles.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {DeliveryGas} from "src/messaging/DeliveryGas.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {CrossProxy} from "src/account/CrossProxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice What a transceiver needs from the transmitter logic it arms an account with.
interface ITransmitterInit {
    function initialize(address owner, address transceiver, bytes32 salt) external;
}

/// @notice The one thing a transceiver tells an account after creating it.
/// @dev The single exception to a transceiver having no authority over an account: the
///      account cannot learn its receiver's address on a chain this one cannot derive, and
///      only its transceiver authenticates the message carrying it.
interface IAccountReceiverReport {
    function onDestinationReceiverReported(bytes32 chainKey, bytes calldata receiver) external;
}

/// @notice What a transceiver is configured with, once, at initialization.
/// @dev A struct, not loose arguments: initializers sit near the stack limit at `paris`.
struct TransceiverConfig {
    /// The only chance to name gateways (see `Roles.grantRole`).
    address[] gateways;
    address transmitterImplementation;
    address receiverImplementation;
    /// The governor's account, named by its owner, salt, and home: its transmitter
    /// on that home, its receiver everywhere else. It owns this transceiver.
    address governorOwner;
    bytes32 governorSalt;
    /// The governor's home as an ERC-7930 chain identifier, which becomes its route here.
    bytes governorHome;
    /// Where bootstrap fees go and the report float leaves to. Write-once.
    address treasury;
    /// The routing `setRouting` would set, so that on any chain but the governor's home this
    /// transceiver can accept the bootstrap that creates its owner; the home must be
    /// `Predetermined` and not suspended. Zero leaves it to the owner, which only the governor's
    /// home can do.
    IChainRegistryRefs chainRegistry;
    bytes32 messageProvider;
    Provenance minCounterpartProvenance;
}

/// @title TransceiverCore
/// @notice The state, events, errors, and internal logic a transceiver's two contracts share:
///         `TransceiverBase`, which holds the paths every message takes, and
///         `TransceiverExtension`, which holds initialization, owner configuration, and views and
///         runs by `DELEGATECALL` from `TransceiverBase`'s `fallback`.
///
/// @dev Both inherit this contract and nothing else that declares sequential storage before it,
///      so the fields below sit at the same slots in each (R8.2). A provider's own fields come
///      after them and are never touched by the extension.
abstract contract TransceiverCore is Initializable, OutboundBase, Roles, OwnableUpgradeable {
    /// This chain's chainKey: the home of every account this transceiver creates as a
    /// transmitter.
    /// @dev An immutable of each implementation, fixed when it is deployed on this chain, so a
    ///      chain split cannot move an account's derivation. `TransceiverBase` refuses an
    ///      extension whose value differs from its own.
    bytes32 public immutable localChainKey;

    /// @notice The initcode hash every crossecute account deploys from, for transmitters and
    ///         receivers alike. See `CrossProxy` for why it has no constructor arguments.
    /// @dev An input to Ethereum's CREATE2 formula only. zkSync deploys from a zksolc artifact
    ///      hash instead; see `_predictCrossAccount`.
    /// @dev Immutable, not constant: a constant is evaluated at runtime, which would put the
    ///      initcode in every runtime that reads this (#70); an immutable puts it in initcode only.
    ///      Computed rather than written out so a build with other compiler settings, such as
    ///      `forge coverage`'s unoptimized one, derives the accounts it deploys.
    bytes32 public immutable CROSS_PROXY_INIT_CODE_HASH = keccak256(type(CrossProxy).creationCode);

    /// The transmitter logic every account homed here is armed with. Write-once: accounts
    /// lock when armed, so a change would split them into two logic versions by creation time.
    // forge-lint: disable-next-line(unused-state-variables) read only by `TransceiverBase` and `TransceiverExtension`
    address internal _transmitterImplementation;
    /// The receiver logic every account homed elsewhere is armed with. Write-once.
    // forge-lint: disable-next-line(unused-state-variables) read only by `TransceiverBase` and `TransceiverExtension`
    address internal _receiverImplementation;

    /// Whether account addresses here differ from Ethereum's CREATE2. When true, every receiver
    /// created here is reported to its home, which cannot derive it. Write-once, and set by the
    /// contract rather than its caller, so it cannot disagree with `_predictCrossAccount`.
    // forge-lint: disable-next-line(unused-state-variables) read only by `TransceiverBase` and `TransceiverExtension`
    bool internal _addressesDiverge;

    /// The registry this transceiver reads provenance and derivations from.
    IChainRegistryRefs internal _chainRegistry;
    /// keccak256 of this transceiver's message provider name, e.g. "layerzero".
    bytes32 internal _messageProvider;
    /// The weakest counterpart provenance this transceiver will send to or accept from.
    /// @dev A parity-chain counterpart is `Predetermined`. Solana, Sui, Aptos, Starknet, zkSync,
    ///      and Tron reach only `Unique`, so this decides whether this transceiver talks to them.
    Provenance internal _minCounterpartProvenance;

    /// chainKey => what standing an account up there costs, on top of the message fee.
    /// @dev Pays for the return leg on a chain that has one: a diverging chain reports each
    ///      account home from its float. Zero by default, so parity destinations, which never
    ///      report, pay nothing. The fee lands in this chain's treasury in this chain's
    ///      currency; the float there is funded out of band.
    // forge-lint: disable-next-line(unused-state-variables) read only by `TransceiverBase` and `TransceiverExtension`
    mapping(bytes32 => uint256) internal _bootstrapFee;

    /// Where a bootstrap fee goes, the moment it is charged, and the only address the report
    /// float leaves to. Write-once.
    // forge-lint: disable-next-line(unused-state-variables) read only by `TransceiverBase` and `TransceiverExtension`
    address internal _treasury;

    /// True only while a receiver report is being sent, which pays from this contract's float.
    bool internal _reporting;

    event CrossAccountCreated(address indexed owner, address indexed account, bytes32 salt, bytes32 homeChainKey);
    /// @dev Path B's record, since a transceiver is not an ERC-7786 gateway source and emits
    ///      no `MessageSent`. `(chainKey, owner, salt)` identifies the account.
    event BootstrapSent(bytes32 indexed destinationChainKey, address indexed owner, bytes32 salt);
    event TransmitterImplementationSet(address implementation);
    event ReceiverImplementationSet(address implementation);
    event AddressesDivergeSet(bool addressesDiverge);
    event RoutingSet(address chainRegistry, bytes32 messageProvider, Provenance minCounterpartProvenance);
    event BootstrapFeeSet(bytes32 indexed chainKey, uint256 fee);
    event BootstrapFeePaid(bytes32 indexed chainKey, address indexed to, uint256 amount);
    event DestinationReceiverReported(bytes32 indexed chainKey, address indexed owner, bytes32 salt, address account);
    event ReceiverReported(bytes32 indexed home, address indexed owner, bytes32 salt, address receiver);
    event Withdrawn(address indexed to, uint256 amount);

    error ZeroOwner();
    /// @dev The caller is not the account `(owner, salt)` resolves to.
    error NotTheAccount(address owner, bytes32 salt, address caller);
    error CrossAccountExists(address owner, bytes32 salt, address account);
    /// @dev `_predictCrossAccount` and `_deployAccount` disagree: a variant on a diverging chain
    ///      overrode one and not the other.
    error AccountAddressMismatch(address predicted, address deployed);
    error NoAccountImplementation();
    error NoTreasury();
    /// @dev The counterpart on that chain is not a 20-byte EVM address, so no EVM CREATE2
    ///      prediction applies there.
    error CounterpartNotEvm(bytes32 chainKey);
    error NoChainRegistry();
    /// @dev The registry holds no deployment record for this provider.
    error NoProviderDeployment();
    /// @dev The route resolved to a known chain, but the sender is not its counterpart.
    error NotCounterpart(bytes32 chainKey);
    /// @dev The registry has suspended the chain.
    error ChainSuspended(bytes32 chainKey);
    /// @dev The chain's grade is below this transceiver's bar.
    error InsufficientCounterpartProvenance(bytes32 chainKey, Provenance grade);
    /// @dev Re-pointing a counterpart would redirect the destination; moving one is a redeploy.
    error CounterpartAlreadySet(bytes32 chainKey);
    /// @dev A `Predetermined` chain's counterpart is `_parityAddress`, in use before any is
    ///      recorded, so a recorded one may only restate it.
    error CounterpartNotParity(bytes32 chainKey);
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
    /// @dev This chain is never a destination or an origin: an account homed here is its
    ///      transmitter, and a receiver here would collide with it.
    error IsLocalChain(bytes32 chainKey);
    /// @dev The caller sent less than the destination's fee.
    error InsufficientBootstrapFee(uint256 required, uint256 provided);
    /// @dev The destination reports its receivers, and its bootstrap fee is unset.
    error NoBootstrapFee(bytes32 chainKey);
    error FeeTransferFailed(address to, uint256 amount);
    /// @dev An EVM receiver can only answer to an EVM transmitter.
    error SourceTransmitterNotEvm(bytes32 transmitter);
    /// @dev A receiver homed on a `Predetermined` chain landed off its transmitter's address, so
    ///      the origin's provider id, route, or transceiver address disagree with this chain's.
    ///      Refused on the first bootstrap rather than leaving every such account unreachable.
    error ParityBroken(address receiver, address sourceTransmitter);
    error NotTreasury(address caller);
    error WithdrawFailed(uint256 amount);

    constructor() {
        localChainKey = ChainKey.local();
    }

    /* ============================== account derivation ============================= */

    /// @notice The salt an owner's account deploys at, on every chain.
    /// @dev The owner is the identity every chain names; the salt lets one owner hold several
    ///      accounts; the home separates the same owner and salt homed on two chains, whose
    ///      transmitter on one would otherwise sit where the other's receiver lands. The home
    ///      is its own field: adding or XORing it into `salt` would let one owner make two
    ///      homes collide. `abi.encode` is fixed-width, so no two triples collide.
    function _accountSalt(address owner, bytes32 salt, bytes32 homeChainKey) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt, homeChainKey));
    }

    /// @notice Where an owner's account lives on this chain, before it exists.
    /// @dev Ethereum's CREATE2, identical wherever the formula holds since all three inputs
    ///      are: this address (one per provider on every chain), the salt, and a constant
    ///      initcode. zkSync and Tron derive differently, so a variant there overrides this,
    ///      in both its `TransceiverBase` and its extension, and `_deployAccount` with it;
    ///      `_createCrossAccount` checks the two agree.
    function _predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        virtual
        returns (address)
    {
        return Create2.computeAddress(
            _accountSalt(owner, salt, homeChainKey), CROSS_PROXY_INIT_CODE_HASH, address(this)
        );
    }

    /// @notice `(owner, salt)`'s account homed on this chain: its transmitter here.
    /// @dev One expression for the bootstrap caller check, the transmitter a bootstrap and its
    ///      quote carry, and every lookup of an account a report is for, so they cannot drift.
    function _localAccount(address owner, bytes32 salt) internal view returns (address) {
        return _predictCrossAccount(owner, salt, localChainKey);
    }

    /// @notice The exact report bytes for `(owner, salt)` and `receiver`.
    function _reportPayload(address owner, bytes32 salt, address receiver) internal view returns (bytes memory) {
        return Envelope.encodeReceiverReport(owner, salt, Erc7930.encodeEvm(block.chainid, receiver));
    }

    /* ================================= counterparts ================================ */

    /// @inheritdoc OutboundBase
    ///
    /// @dev Applies the registry's per-chain grade and suspension, which every provider's
    ///      transceiver reads alike. Every bootstrap and report sent, and every delivery
    ///      authenticated, goes through here, so a suspended chain is cut off both ways.
    ///
    /// @dev An unset counterpart on a `Predetermined` chain is `_parityAddress(chainKey)`: every
    ///      transceiver of a provider is a `CrossProxy` deployed through `CrossProxyDeployer` by
    ///      one caller at one salt, which is what `Predetermined` means (#33).
    function _counterpartOn(bytes32 chainKey) internal view virtual override returns (bytes memory) {
        if (chainKey == localChainKey) revert IsLocalChain(chainKey);
        if (address(_chainRegistry) == address(0)) revert NoChainRegistry();
        if (_chainRegistry.isSuspended(chainKey)) revert ChainSuspended(chainKey);

        Provenance grade = _chainRegistry.provenanceFor(chainKey);
        if (uint8(grade) < uint8(_minCounterpartProvenance)) {
            revert InsufficientCounterpartProvenance(chainKey, grade);
        }

        if (!hasCounterpart(chainKey)) {
            if (grade != Provenance.Predetermined) revert NoCounterpartFor(chainKey);
            return abi.encodePacked(_parityAddress(chainKey));
        }
        return OutboundBase._counterpartOn(chainKey);
    }

    /// @notice The counterpart on `chainKey` as an EVM address, refusing any other width.
    function _evmCounterpartOn(bytes32 chainKey) internal view returns (address) {
        bytes memory there = _counterpartOn(chainKey);
        if (there.length != 20) revert CounterpartNotEvm(chainKey);
        // forge-lint: disable-next-line(unsafe-typecast) length checked above
        return address(bytes20(there));
    }

    /// @notice Where this provider's transceiver sits on `chainKey`, a chain that uses
    ///         Ethereum's CREATE2: the default counterpart there.
    /// @dev This contract's own address wherever that formula holds here too. A transceiver on
    ///      zkSync or Tron sits elsewhere, so it overrides this with `_registryParityAddress`.
    function _parityAddress(bytes32) internal view virtual returns (address) {
        return address(this);
    }

    /// @notice Where this provider's transceiver sits on the `Predetermined` chain `chainKey`, from
    ///         the registry's write-once deployment record.
    /// @dev Reverts while the provider's deployment is unrecorded, so nothing authenticates or
    ///      is sent to a guessed address.
    function _registryParityAddress(bytes32 chainKey) internal view returns (address) {
        return _chainRegistry.predictTransceiver(chainKey, _messageProvider);
    }

    /* =================================== sending =================================== */

    /// @notice Where a provider returns an overpaid fee: whoever paid it.
    /// @dev A report's overpayment returns to the float it was paid from. Anything else, a
    ///      bootstrap above all, refunds the account that paid.
    function _refundTo() internal view virtual override returns (address) {
        return _reporting ? address(this) : msg.sender;
    }

    /// @inheritdoc OutboundBase
    /// @dev By the envelope, not `_reporting`, so `quoteMessage` prices a report as it is sent.
    ///      A report's gas is fixed here because the float pays for it.
    function _defaultGas(bytes memory payload) internal pure override returns (uint256) {
        return Envelope.isReceiverReport(payload) ? DeliveryGas.REPORT : DeliveryGas.BOOTSTRAP;
    }
}
