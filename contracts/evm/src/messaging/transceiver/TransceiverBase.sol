// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Roles} from "src/messaging/Roles.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {CrossProxy, ICrossProxy} from "src/account/CrossProxy.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
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
    /// The crossecute msig's own account, named by its owner, salt, and home: its transmitter
    /// on that home, its receiver everywhere else. It owns this transceiver.
    address governorOwner;
    bytes32 governorSalt;
    /// The governor's home as an ERC-7930 chain identifier, which becomes its route here.
    bytes governorHome;
    /// Where bootstrap fees go and the report float leaves to. Write-once.
    address treasury;
    /// The routing `setRouting` would set, so that on any chain but the governor's home this
    /// transceiver can accept the bootstrap that creates its owner; the home must be `Derived`
    /// and not suspended. Zero leaves it to the owner, which only the governor's home can do.
    IChainRegistryRefs chainRegistry;
    bytes32 messageProvider;
    Provenance minCounterpartProvenance;
}

/// @title TransceiverBase
/// @notice One transceiver per chain per provider. It creates transmitters for accounts homed
///         here and receivers for accounts homed on any configured origin, and it sends and
///         accepts both bootstraps and receiver reports.
///
/// @dev An account's CREATE2 salt is `(owner, salt, homeChainKey)` and nothing else, so one
///      transmitter has one receiver per destination, at an address fixed before the first
///      message, and the transmitter an account has here never collides with the receiver an
///      account homed elsewhere has here. A receiver is made only by an authenticated bootstrap.
///
/// @dev Runs no payload of its own: an inbound message is an `Envelope`, acted on in
///      `_handleInbound`, and a bootstrap creates the account and runs its payload in the same
///      delivery. A first payload that should wait carries a call to the new receiver's own
///      `commit`. No approvals are held here, so no origin can approve or cancel on another's
///      behalf.
///
/// @dev Owned by the crossecute msig's own account on this chain, derived at initialization
///      rather than typed, and configured by payloads the msig sends from its home. The owner
///      configures and can move no money. `GATEWAY_ROLE` is fixed at initialization with no
///      revoke path, since a transceiver's transports serve every account on its chain; a
///      compromised transport means a new transceiver.
abstract contract TransceiverBase is Initializable, OutboundBase, Roles, OwnableUpgradeable, IERC1822Proxiable {
    /// This implementation's own address, so `proxiableUUID` can refuse a call through a proxy.
    address private immutable _self = address(this);

    /// This chain's chainKey: the home of every account this transceiver creates as a
    /// transmitter.
    /// @dev An immutable of the implementation, fixed when it is deployed on this chain, so a
    ///      chain split cannot move an account's derivation. Each chain deploys its own
    ///      implementation, as it must for its provider endpoints.
    bytes32 public immutable localChainKey;

    /// @notice The initcode hash every crossecute account deploys from, for transmitters and
    ///         receivers alike. See `CrossProxy` for why it has no constructor arguments.
    /// @dev An input to Ethereum's CREATE2 formula only. zkSync deploys from a zksolc artifact
    ///      hash instead; see `predictCrossAccount`.
    bytes32 public constant CROSS_PROXY_INIT_CODE_HASH = keccak256(type(CrossProxy).creationCode);

    /// The transmitter logic every account homed here is armed with. Write-once: accounts
    /// lock when armed, so a change would split them into two logic versions by creation time.
    address public transmitterImplementation;
    /// The receiver logic every account homed elsewhere is armed with. Write-once.
    address public receiverImplementation;

    /// Whether account addresses here differ from Ethereum's CREATE2. When true, every receiver
    /// created here is reported to its home, which cannot derive it. Write-once, and set by the
    /// contract rather than its caller, so it cannot disagree with `predictCrossAccount`.
    bool public addressesDiverge;

    /// The registry this transceiver reads provenance and derivations from.
    IChainRegistryRefs public chainRegistry;
    /// keccak256 of this transceiver's message provider name, e.g. "layerzero".
    bytes32 public messageProvider;
    /// The weakest counterpart provenance this transceiver will send to or accept from.
    /// @dev A parity-chain counterpart is `Derived`. Solana, Sui, Aptos, Starknet, zkSync, and
    ///      Tron reach only `Attested`, so this decides whether this transceiver talks to them.
    Provenance public minCounterpartProvenance;

    /// chainKey => what standing an account up there costs, on top of the message fee.
    /// @dev Pays for the return leg on a chain that has one: a diverging chain reports each
    ///      account home from its float. Zero by default, so parity destinations, which never
    ///      report, pay nothing. The fee lands in this chain's treasury in this chain's
    ///      currency; the float there is funded out of band.
    mapping(bytes32 => uint256) public bootstrapFee;

    /// @notice Where a bootstrap fee goes, the moment it is charged, and the only address the
    ///         report float leaves to. Write-once.
    address public treasury;

    /// True only while a receiver report is being sent, which pays from this contract's float.
    bool private _reporting;

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

    /// @dev `proxiableUUID` was reached through a proxy rather than on the implementation.
    error UnauthorizedCallContext();
    error ZeroOwner();
    /// @dev The caller is not the account `(owner, salt)` resolves to.
    error NotTheAccount(address owner, bytes32 salt, address caller);
    error CrossAccountExists(address owner, bytes32 salt, address account);
    /// @dev `predictCrossAccount` and `_deployAccount` disagree: a variant on a diverging chain
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
    error FeeTransferFailed(address to, uint256 amount);
    /// @dev An EVM receiver can only answer to an EVM transmitter.
    error SourceTransmitterNotEvm(bytes32 transmitter);
    /// @dev A receiver homed on a `Derived` chain landed off its transmitter's address, so the
    ///      origin's provider id, route, or transceiver address disagree with this chain's.
    ///      Refused on the first bootstrap rather than leaving every such account unreachable.
    error ParityBroken(address receiver, address sourceTransmitter);
    error NotTreasury(address caller);
    error WithdrawFailed(uint256 amount);

    constructor() {
        localChainKey = ChainKey.local();
    }

    /* ================================ initialization ============================== */

    /// @notice For a transceiver that derives account addresses Ethereum's way.
    function __TransceiverBase_init(TransceiverConfig memory c) internal onlyInitializing {
        __TransceiverBase_init(c, false);
    }

    /// @notice Configure and grant the gateways.
    ///
    /// @dev `addressesDiverge_` is the contract's own fact: `DivergentTransceiver` passes true,
    ///      having set its derivation inputs first, since the owner is derived here with
    ///      `predictCrossAccount`.
    ///
    /// @dev A transceiver decides which payloads are authentic, so a live upgrade key would be
    ///      a standing ability to forge any message. There is none: the proxy's one upgrade is
    ///      the `upgradeToAndCall` that runs this initializer, authorized against the stub it
    ///      replaces, and this contract has no upgrade function (see `proxiableUUID`). A bug
    ///      here is fixed only by redeploying, which re-derives every account.
    function __TransceiverBase_init(TransceiverConfig memory c, bool addressesDiverge_) internal onlyInitializing {
        if (c.transmitterImplementation == address(0)) revert NoAccountImplementation();
        if (c.receiverImplementation == address(0)) revert NoAccountImplementation();
        if (c.treasury == address(0)) revert NoTreasury();
        if (c.governorOwner == address(0)) revert ZeroOwner();

        // The identifier names the owner's home, so it must be the canonical one for its key.
        bytes32 governorHome = keccak256(c.governorHome);
        _requireNames(c.governorHome, governorHome);

        transmitterImplementation = c.transmitterImplementation;
        emit TransmitterImplementationSet(c.transmitterImplementation);
        receiverImplementation = c.receiverImplementation;
        emit ReceiverImplementationSet(c.receiverImplementation);
        addressesDiverge = addressesDiverge_;
        emit AddressesDivergeSet(addressesDiverge_);
        treasury = c.treasury;

        __Ownable_init(predictCrossAccount(c.governorOwner, c.governorSalt, governorHome));

        // Born accepting the governor's home as an origin: the owner is the governor's
        // account here, which only a bootstrap from that home can create.
        if (address(c.chainRegistry) != address(0)) {
            _setRouting(c.chainRegistry, c.messageProvider, c.minCounterpartProvenance);
            // Only the owner, which that bootstrap creates, could set a counterpart, so the
            // home's must resolve now or the transceiver is never usable (#32).
            if (governorHome != localChainKey) _counterpartOn(governorHome);
        }
        if (governorHome != localChainKey) _setRoute(governorHome, c.governorHome);

        for (uint256 i; i < c.gateways.length; ++i) {
            if (c.gateways[i] != address(0)) {
                grantRole(GATEWAY_ROLE, c.gateways[i]);
            }
        }
    }

    /// @notice ERC-1822's answer that this is an implementation a UUPS proxy may install.
    /// @dev The only part of UUPS a transceiver keeps. A stub proxy installs it once, through
    ///      the `upgradeToAndCall` that runs the initializer, and the transceiver has no upgrade
    ///      function of its own, so once installed no key exists that could replace it.
    ///      Refused through a proxy, as OZ's `notDelegated` does, so a proxy is never installed
    ///      as its own implementation.
    function proxiableUUID() external view returns (bytes32) {
        if (address(this) != _self) revert UnauthorizedCallContext();
        return ERC1967Utils.IMPLEMENTATION_SLOT;
    }

    /* ============================== account manufacture ============================ */

    /// @notice The salt an owner's account deploys at, on every chain.
    /// @dev The owner is the identity every chain names; the salt lets one owner hold several
    ///      accounts; the home separates the same owner and salt homed on two chains, whose
    ///      transmitter on one would otherwise sit where the other's receiver lands. The home
    ///      is its own field: adding or XORing it into `salt` would let one owner make two
    ///      homes collide. `abi.encode` is fixed-width, so no two triples collide.
    function accountSalt(address owner, bytes32 salt, bytes32 homeChainKey) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt, homeChainKey));
    }

    /// @notice Where an owner's account lives on this chain, before it exists.
    /// @dev Ethereum's CREATE2, identical wherever the formula holds since all three inputs
    ///      are: this address (one per provider on every chain), the salt, and a constant
    ///      initcode. zkSync and Tron derive differently, so a variant there overrides this and
    ///      `_deployAccount` together; `_createCrossAccount` checks the two agree.
    function predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        public
        view
        virtual
        returns (address)
    {
        return Create2.computeAddress(accountSalt(owner, salt, homeChainKey), CROSS_PROXY_INIT_CODE_HASH, address(this));
    }

    /// @notice Where `(owner, salt)`'s receiver will sit on `chainKey`, for an account homed on
    ///         this chain, where `chainKey` derives addresses with Ethereum's CREATE2.
    /// @dev Ethereum's CREATE2 over this provider's transceiver there, which is the counterpart
    ///      on that chain. It equals the account's own address only when this chain also uses
    ///      that formula, which is why a transmitter records this rather than `address(this)`.
    ///
    /// @dev The initcode hash is the destination's, not this compiler's: on zkSync and Tron
    ///      `CROSS_PROXY_INIT_CODE_HASH` is the local compiler's and not what an EVM destination
    ///      deploys (#30), so a diverging transceiver takes it from the provider's deployment
    ///      record, which R8.4 holds equal to solc's.
    function predictReceiver(bytes32 chainKey, address owner, bytes32 salt) public view returns (bytes memory) {
        bytes32 initCodeHash = CROSS_PROXY_INIT_CODE_HASH;
        if (addressesDiverge) {
            initCodeHash = chainRegistry.providerDeployment(messageProvider).accountInitCodeHash;
            if (initCodeHash == bytes32(0)) revert NoProviderDeployment();
        }
        return abi.encodePacked(
            Create2.computeAddress(accountSalt(owner, salt, localChainKey), initCodeHash, _evmCounterpartOn(chainKey))
        );
    }

    /// @notice The counterpart on `chainKey` as an EVM address, refusing any other width.
    function _evmCounterpartOn(bytes32 chainKey) internal view returns (address) {
        bytes memory there = _counterpartOn(chainKey);
        if (there.length != 20) revert CounterpartNotEvm(chainKey);
        // forge-lint: disable-next-line(unsafe-typecast) length checked above
        return address(bytes20(there));
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
        return _localAccount(owner, salt);
    }

    /// @notice Deploy the proxy at `salt`, and return where it actually landed.
    /// @dev Separate from the prediction because zkSync diverges in both: a different formula,
    ///      and deployment through a system contract against a pre-published bytecode hash, so
    ///      a variant there emits `new CrossProxy{salt: s}()`. Tron diverges only in the formula.
    function _deployAccount(bytes32 salt) internal virtual returns (address deployed) {
        return Create2.deploy(0, salt, type(CrossProxy).creationCode);
    }

    /// @notice Deploy an owner's account and arm it: a transmitter if it is homed here, a
    ///         receiver otherwise, through the same argument-free proxy.
    ///
    /// @dev Deploy, arm, and lock happen in one call, so no account ever has logic and a live
    ///      upgrade key at once.
    ///
    /// @dev Asserts the deployment landed where `predictCrossAccount` said. Every address the
    ///      protocol publishes comes from that prediction: a transmitter's recorded
    ///      counterpart, a receiver's `sourceTransmitter`, the account a report is forwarded
    ///      to. Without the check a mismatch still fails, but with no revert reason.
    /// @param sourceTransmitter The transmitter a receiver will answer to; zero for a
    ///        transmitter, which answers to its owner.
    function _createCrossAccount(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls
    ) internal returns (address account) {
        if (owner == address(0)) revert ZeroOwner();

        address implementation = _accountImplementation(homeChainKey);
        if (implementation == address(0)) revert NoAccountImplementation();

        account = predictCrossAccount(owner, salt, homeChainKey);
        if (account.code.length != 0) revert CrossAccountExists(owner, salt, account);

        address deployed = _deployAccount(accountSalt(owner, salt, homeChainKey));
        if (deployed != account) revert AccountAddressMismatch(account, deployed);

        ICrossProxy(account)
            .upgradeInitializeAndLock(
                implementation, _accountInitializer(owner, salt, homeChainKey, sourceTransmitter, calls)
            );

        emit CrossAccountCreated(owner, account, salt, homeChainKey);
    }

    /// @notice The logic an account homed on `homeChainKey` is armed with.
    function _accountImplementation(bytes32 homeChainKey) internal view virtual returns (address) {
        return homeChainKey == localChainKey ? transmitterImplementation : receiverImplementation;
    }

    /// @notice The initializer that logic is armed with, run by delegatecall inside the
    ///         upgrade so the account is never live and uninitialized.
    /// @dev The proxy locks in the same call, and an account's own configuration is gated on
    ///      its owner, not this contract, so all provider setup must be in this calldata. A
    ///      transmitter takes its salt, since an account cannot recover it from its own
    ///      address; a receiver answers to the transmitter its bootstrap carried.
    function _accountInitializer(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls
    ) internal view virtual returns (bytes memory) {
        if (homeChainKey == localChainKey) {
            return abi.encodeCall(ITransmitterInit.initialize, (owner, address(this), salt));
        }
        return abi.encodeCall(IReceiverInit.initialize, (sourceTransmitter, calls));
    }

    /// @notice `(owner, salt)`'s account homed on this chain: its transmitter here.
    /// @dev One expression for the bootstrap caller check, the transmitter a bootstrap and its
    ///      quote carry, and every lookup of an account a report is for, so they cannot drift.
    function _localAccount(address owner, bytes32 salt) internal view returns (address) {
        return predictCrossAccount(owner, salt, localChainKey);
    }

    /* =================================== bootstrap ================================= */

    /// @notice Stand an account up on a chain that has none, and carry its payload.
    ///
    /// @dev Callable only by the account `(owner, salt)` resolves to when homed on this chain,
    ///      which is what lets the owner and salt travel in the message without a caller
    ///      claiming another identity. An account homed elsewhere bootstraps from its own home.
    ///
    /// @dev The only send `minCounterpartProvenance` gates, through `_requireRoutable`: it bars
    ///      the first message to a chain, after which the account sends to its receiver
    ///      directly.
    function bootstrap(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external payable {
        bytes32 transmitter = _bootstrapCaller(owner, salt);
        _sendBootstrap(
            destinationChainKey, owner, salt, Envelope.encodeBootstrap(owner, salt, transmitter, calls), attributes
        );
    }

    /// @notice `bootstrap`, for a destination whose calls this chain cannot express.
    /// @dev Which form a caller may use depends on the destination's chain type, enforced by
    ///      the transmitter: this contract sees only a chainKey.
    function bootstrapElements(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        bytes[] calldata elements,
        bytes[] calldata attributes
    ) external payable {
        bytes32 transmitter = _bootstrapCaller(owner, salt);
        _sendBootstrap(
            destinationChainKey,
            owner,
            salt,
            Envelope.encodeBootstrapElements(owner, salt, transmitter, elements),
            attributes
        );
    }

    /// @notice What `bootstrap` would cost, before anything is spent.
    /// @dev Applies `_requireRoutable`, so it fails wherever the send would, but not
    ///      `bootstrap`'s caller check: a quote is taken before the account exists.
    function quoteBootstrap(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        return _quoteBootstrap(
            destinationChainKey,
            Envelope.encodeBootstrap(owner, salt, _transmitterWord(_localAccount(owner, salt)), calls),
            attributes
        );
    }

    /// @notice `quoteBootstrap`, for a destination whose calls this chain cannot express.
    function quoteBootstrapElements(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        bytes[] calldata elements,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        return _quoteBootstrap(
            destinationChainKey,
            Envelope.encodeBootstrapElements(owner, salt, _transmitterWord(_localAccount(owner, salt)), elements),
            attributes
        );
    }

    /// @notice Refuse any caller but the account `(owner, salt)` resolves to here, and return
    ///         it as the bootstrap carries it.
    function _bootstrapCaller(address owner, bytes32 salt) private view returns (bytes32) {
        address account = _localAccount(owner, salt);
        if (account != msg.sender) revert NotTheAccount(owner, salt, msg.sender);
        return _transmitterWord(account);
    }

    /// @dev One send path for both envelope forms. The provenance bar lives inside
    ///      `_requireRoutable`: an under-graded counterpart, or an unconfigured route, reverts
    ///      before anything crosses.
    function _sendBootstrap(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        bytes memory envelope,
        bytes[] calldata attributes
    ) private {
        _requireRoutable(destinationChainKey);
        emit BootstrapSent(destinationChainKey, owner, salt);
        _sendMessage(_recipientOn(destinationChainKey), envelope, attributes, _bootstrapSendValue(destinationChainKey));
    }

    /// @dev The quote of `_sendBootstrap`, over the same envelope, plus the destination's fee.
    function _quoteBootstrap(bytes32 destinationChainKey, bytes memory envelope, bytes[] calldata attributes)
        private
        view
        returns (uint256)
    {
        _requireRoutable(destinationChainKey);
        return
            _quoteMessage(_recipientOn(destinationChainKey), envelope, attributes) + bootstrapFee[destinationChainKey];
    }

    /// @notice An EVM transmitter as a bootstrap carries it: left-padded to a word.
    function _transmitterWord(address transmitter) private pure returns (bytes32) {
        return bytes32(uint256(uint160(transmitter)));
    }

    /// @notice Set what standing an account up on `chainKey` costs.
    /// @dev Rebindable: a price redirects nothing.
    function setBootstrapFee(bytes32 chainKey, uint256 fee) external onlyOwner {
        bootstrapFee[chainKey] = fee;
        emit BootstrapFeeSet(chainKey, fee);
    }

    /// @notice Take the destination's fee off the top of `msg.value`, forward it, and return
    ///         what is left for the send.
    /// @dev Paid before the send, which reaches a provider endpoint and arbitrary code beyond
    ///      it; a later revert unwinds the payment too. `call` rather than `transfer`, so a
    ///      treasury contract is not held to the 2300-gas stipend.
    function _bootstrapSendValue(bytes32 chainKey) internal returns (uint256) {
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

    /* ================================ configuration ================================ */

    /// @notice Teach this transceiver how a chain is named. Write-once, and the owner's.
    /// @dev A binding wraps this only where it keeps a provider-native id.
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
        _setRouting(chainRegistry_, messageProvider_, minCounterpartProvenance_);
    }

    function _setRouting(
        IChainRegistryRefs chainRegistry_,
        bytes32 messageProvider_,
        Provenance minCounterpartProvenance_
    ) private {
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

    /// @notice Record where this provider's transceiver sits on another chain.
    ///
    /// @dev Held here, not in the registry, because a location is per (chain, provider) and
    ///      this transceiver is that pair. The registry holds what is common to every provider:
    ///      `provenanceFor(chainKey)`. Write-once: re-pointing a counterpart redirects it.
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

    /* ================================= counterparts ================================ */

    /// @inheritdoc OutboundBase
    ///
    /// @dev Applies the registry's per-chain grade and suspension, which every provider's
    ///      transceiver reads alike. Every bootstrap and report sent, and every delivery
    ///      authenticated, goes through here, so a suspended chain is cut off both ways.
    ///
    /// @dev An unset counterpart on a `Derived` chain is `_parityAddress(chainKey)`: every
    ///      transceiver of a provider is deployed through Arachnid's factory at one salt and
    ///      initcode, which is what `Derived` means (#33).
    function _counterpartOn(bytes32 chainKey) internal view virtual override returns (bytes memory) {
        if (chainKey == localChainKey) revert IsLocalChain(chainKey);
        if (address(chainRegistry) == address(0)) revert NoChainRegistry();
        if (chainRegistry.isSuspended(chainKey)) revert ChainSuspended(chainKey);

        Provenance grade = chainRegistry.provenanceFor(chainKey);
        if (uint8(grade) < uint8(minCounterpartProvenance)) {
            revert InsufficientCounterpartProvenance(chainKey, grade);
        }

        if (!hasCounterpart(chainKey)) {
            if (grade != Provenance.Derived) revert NoCounterpartFor(chainKey);
            return abi.encodePacked(_parityAddress(chainKey));
        }
        return OutboundBase._counterpartOn(chainKey);
    }

    /// @notice Where this provider's transceiver sits on `chainKey`, a chain that uses
    ///         Ethereum's CREATE2: the default counterpart there.
    /// @dev This contract's own address wherever that formula holds here too. A transceiver on
    ///      zkSync or Tron sits elsewhere, so it derives the address from the registry instead.
    function _parityAddress(bytes32) internal view virtual returns (address) {
        return address(this);
    }

    /* =================================== inbound =================================== */

    /// @notice The funnel every binding routes an arriving message into.
    ///
    /// @dev Authentication runs here, before anything is decoded, so a binding only translates
    ///      its SDK's callback into these arguments.
    ///
    /// @param route   How the source chain is named, as the provider reported it.
    /// @param sender  The counterpart's address on that chain, in that chain's own format.
    /// @param message The body: see `Envelope`.
    function _onInbound(bytes memory route, bytes memory sender, bytes calldata message) internal {
        bytes32 chainKey = _authenticateOrigin(route, sender);
        _handleInbound(chainKey, message);
    }

    /// @notice Establish which chain this came from, and refuse it if the sender is not that
    ///         chain's counterpart.
    /// @dev The route names the chain; the sender must be its counterpart at this
    ///      transceiver's provenance bar. An unknown route reverts in `chainKeyOfRoute`.
    function _authenticateOrigin(bytes memory route, bytes memory sender)
        internal
        view
        virtual
        returns (bytes32 chainKey)
    {
        chainKey = chainKeyOfRoute(route);
        if (keccak256(sender) != keccak256(_counterpartOn(chainKey))) {
            revert NotCounterpart(chainKey);
        }
    }

    /// @notice Act on an authenticated message.
    /// @dev A report is for an account homed here. A bootstrap creates a receiver homed on the
    ///      authenticated origin, never on a chain the message states. Each decoder checks the
    ///      `Envelope` kind, so a wrong shape is refused by name rather than misread.
    function _handleInbound(bytes32 origin, bytes calldata message) internal virtual {
        if (Envelope.kindOf(message) == Envelope.RECEIVER_REPORT) {
            (address reportOwner, bytes32 reportSalt, bytes memory interop) = Envelope.decodeReceiverReport(message);
            _onDestinationReceiver(origin, reportOwner, reportSalt, interop);
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

    /* ================================== the report ================================= */

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

    /// @notice A destination reports where it created the receiver of an account homed here.
    ///
    /// @dev For chains this one cannot derive: Starknet's Pedersen derivation, and zkSync's and
    ///      Tron's CREATE2 formulas. Internal, so reachable only from an authenticated
    ///      `_onInbound`.
    ///
    /// @dev Written to the account, not the registry, because the transmitter is what
    ///      addresses that receiver and the registry is out of the send path. The registry
    ///      still decides which chains may report (`requiresReceiverCallback`), so a chain this
    ///      one derives cannot replace a `Derived` fact with a reported one.
    ///
    /// @dev The destination cannot choose the account: `chainKey` is authenticated and the
    ///      account is `predictCrossAccount` of the stated pair, the derivation `bootstrap`
    ///      checked the caller against. The account refuses a second report.
    ///
    /// @dev The reported address must be on the reporting chain. An authenticated transceiver
    ///      can still report a wrong address on its own chain; the account keeps the first
    ///      one, so a compromised transceiver costs only its own chain.
    /// @param interop Canonical ERC-7930 bytes for the receiver on the destination.
    function _onDestinationReceiver(bytes32 chainKey, address owner, bytes32 salt, bytes memory interop) internal {
        if (address(chainRegistry) == address(0)) revert NoChainRegistry();
        if (owner == address(0)) revert ZeroOwner();
        if (!chainRegistry.requiresReceiverCallback(chainKey)) {
            revert ChainDoesNotReport(chainKey);
        }

        bytes32 reported = Erc7930.chainKey(interop);
        if (reported != chainKey) revert ReportedChainMismatch(chainKey, reported);

        address account = _localAccount(owner, salt);
        IAccountReceiverReport(account).onDestinationReceiverReported(chainKey, Erc7930.parseStrict(interop).addr);
        emit DestinationReceiverReported(chainKey, owner, salt, account);
    }

    /// @notice Whether `chainKey` reports its receiver address back, rather than this
    ///         transceiver deriving it.
    /// @dev True exactly where this contract cannot recompute an address (zkSync, Tron, every
    ///      non-EVM VM), from the same registry answer `_onDestinationReceiver` enforces. With
    ///      no registry it answers false; `_requireRoutable` then refuses the bootstrap. This
    ///      chain is refused first: a transmitter's bootstrap asks this before anything else,
    ///      and the registry need not list its own chain.
    function reportsReceiver(bytes32 chainKey) public view returns (bool) {
        if (chainKey == localChainKey) revert IsLocalChain(chainKey);
        if (address(chainRegistry) == address(0)) return false;
        return chainRegistry.requiresReceiverCallback(chainKey);
    }

    /// @notice Where a provider returns an overpaid fee: whoever paid it.
    /// @dev A report's overpayment returns to the float it was paid from. Anything else, a
    ///      bootstrap above all, refunds the account that paid.
    function _refundTo() internal view virtual override returns (address) {
        return _reporting ? address(this) : msg.sender;
    }

    /* =================================== the float ================================= */

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
