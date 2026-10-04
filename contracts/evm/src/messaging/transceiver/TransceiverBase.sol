// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Call} from "src/messaging/Call.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {CrossProxy, ICrossProxy} from "src/account/CrossProxy.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title TransceiverBase
/// @notice Authentication, routing, manufacture, and the upgrade lock: the half that is
///         identical wherever a transceiver is deployed.
///
/// @dev An account's home is part of its salt, so the transmitter an account has here and the
///      receiver an account homed elsewhere has here never collide, though one contract makes
///      both. A receiver is made only by an authenticated bootstrap.
///
/// @dev Runs no payload of its own: an inbound message is an `Envelope`, acted on in
///      `_handleInbound`, and a bootstrap creates the account and runs its payload in the same
///      delivery. A first payload that should wait carries a call to the new receiver's own
///      `commit`. No approvals are held here, so no origin can approve or cancel on another's
///      behalf.
///
/// @dev No authority here. `Ownable` is on `HubTransceiverBase`; a spoke's configuration is
///      written in its initializer with no setters. `GATEWAY_ROLE` is fixed at initialization
///      with no revoke path, since a transceiver's transports serve every account on its
///      chain; a compromised transport means a new transceiver, so a deployment names every
///      gateway it may need up front.
///
/// @dev What differs between hub and spoke is behind `_counterpartOn` and `_routeTo`: the hub
///      has N counterparts graded by a registry, a spoke one, given at initialization.
///
/// @dev An account's CREATE2 salt is `(owner, salt, homeChainKey)` and nothing else, so one
///      transmitter has one receiver per destination, at an address fixed before the first
///      message.
abstract contract TransceiverBase is Initializable, OutboundBase, UUPSUpgradeable {
    /// Once true, no further implementation change is possible. One-way.
    bool public upgradesLocked;

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

    event UpgradesLocked();

    constructor() {
        localChainKey = ChainKey.local();
    }
    event CrossAccountCreated(address indexed owner, address indexed account, bytes32 salt, bytes32 homeChainKey);

    error UpgradesAreLocked();
    error ZeroOwner();
    /// @dev The caller is not the account `(owner, salt)` resolves to.
    error NotTheAccount(address owner, bytes32 salt, address caller);
    error CrossAccountExists(address owner, bytes32 salt, address account);
    /// @dev `predictCrossAccount` and `_deployAccount` disagree: a spoke on a diverging chain
    ///      overrode one and not the other.
    error AccountAddressMismatch(address predicted, address deployed);
    error NoAccountImplementation();
    /// @dev The counterpart on that chain is not a 20-byte EVM address, so no EVM CREATE2
    ///      prediction applies there.
    error CounterpartNotEvm(bytes32 chainKey);

    /* ================================== routing ================================ */

    /// @dev Path B's record, since a transceiver is not an ERC-7786 gateway source and emits
    ///      no `MessageSent`. `(chainKey, owner, salt)` identifies the account.
    event BootstrapSent(bytes32 indexed destinationChainKey, address indexed owner, bytes32 salt);

    /* ============================ account manufacture ========================== */

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
    ///      are: this address (hub and spoke share one), the salt, and a constant initcode.
    ///      zkSync and Tron derive differently, so a spoke there overrides this and
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
    function predictReceiver(bytes32 chainKey, address owner, bytes32 salt) public view returns (bytes memory) {
        bytes memory there = _counterpartOn(chainKey);
        if (there.length != 20) revert CounterpartNotEvm(chainKey);
        // forge-lint: disable-next-line(unsafe-typecast) length checked above
        address transceiverThere = address(bytes20(there));
        return abi.encodePacked(
            Create2.computeAddress(
                accountSalt(owner, salt, localChainKey), CROSS_PROXY_INIT_CODE_HASH, transceiverThere
            )
        );
    }

    /// @notice Deploy the proxy at `salt`, and return where it actually landed.
    /// @dev Separate from the prediction because zkSync diverges in both: a different formula,
    ///      and deployment through a system contract against a pre-published bytecode hash, so
    ///      a spoke there emits `new CrossProxy{salt: s}()`. Tron diverges only in the formula.
    function _deployAccount(bytes32 salt) internal virtual returns (address deployed) {
        return Create2.deploy(0, salt, type(CrossProxy).creationCode);
    }

    /// @notice Deploy an owner's account and arm it with the logic this side installs.
    ///
    /// @dev A hub installs a transmitter and a spoke a receiver, through the same
    ///      argument-free proxy at the same salt; only `_accountImplementation` differs.
    ///      Deploy, arm, and lock happen in one call, so no account ever has logic and a live
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

    /// @notice Stand an account up on a chain that has none, and carry its payload.
    ///
    /// @dev Callable only by the account `(owner, salt)` resolves to when homed on this chain,
    ///      which is what lets the owner and salt travel in the message without a caller
    ///      claiming another identity. An account homed elsewhere bootstraps from its own home.
    ///
    /// @dev The only caller of `_requireRoutable`, so the only place `minCounterpartProvenance`
    ///      applies: it bars the first message to a chain, after which the account sends to
    ///      its receiver directly.
    function bootstrap(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external payable {
        address account = _localAccount(owner, salt);
        if (account != msg.sender) revert NotTheAccount(owner, salt, msg.sender);

        // The provenance bar lives inside this check: an under-graded counterpart, or an
        // unconfigured route, reverts before anything crosses.
        _requireRoutable(destinationChainKey);

        emit BootstrapSent(destinationChainKey, owner, salt);
        _sendMessage(
            _recipientOn(destinationChainKey),
            Envelope.encodeBootstrap(owner, salt, _transmitterWord(account), calls),
            attributes,
            _bootstrapSendValue(destinationChainKey)
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
        address account = _localAccount(owner, salt);
        if (account != msg.sender) revert NotTheAccount(owner, salt, msg.sender);

        _requireRoutable(destinationChainKey);

        emit BootstrapSent(destinationChainKey, owner, salt);
        _sendMessage(
            _recipientOn(destinationChainKey),
            Envelope.encodeBootstrapElements(owner, salt, _transmitterWord(account), elements),
            attributes,
            _bootstrapSendValue(destinationChainKey)
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
        _requireRoutable(destinationChainKey);
        uint256 surcharge = _bootstrapSurcharge(destinationChainKey);
        return _quoteMessage(
            _recipientOn(destinationChainKey),
            Envelope.encodeBootstrap(owner, salt, _transmitterWord(_localAccount(owner, salt)), calls),
            attributes
        ) + surcharge;
    }

    /// @notice `quoteBootstrap`, for a destination whose calls this chain cannot express.
    function quoteBootstrapElements(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        bytes[] calldata elements,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        _requireRoutable(destinationChainKey);
        uint256 surcharge = _bootstrapSurcharge(destinationChainKey);
        return _quoteMessage(
            _recipientOn(destinationChainKey),
            Envelope.encodeBootstrapElements(owner, salt, _transmitterWord(_localAccount(owner, salt)), elements),
            attributes
        ) + surcharge;
    }

    /// @notice `(owner, salt)`'s account homed on this chain: its transmitter here.
    /// @dev One expression for the bootstrap caller check, the transmitter a bootstrap and its
    ///      quote carry, and every hub lookup of an account, so they cannot drift apart.
    function _localAccount(address owner, bytes32 salt) internal view returns (address) {
        return predictCrossAccount(owner, salt, localChainKey);
    }

    /// @notice An EVM transmitter as a bootstrap carries it: left-padded to a word.
    function _transmitterWord(address transmitter) private pure returns (bytes32) {
        return bytes32(uint256(uint160(transmitter)));
    }

    /// @notice What this transceiver charges on top of the message, per destination.
    /// @dev In the quote, or a caller funding the quote exactly would hit
    ///      `InsufficientBootstrapFee` (R2.5).
    function _bootstrapSurcharge(bytes32) internal view virtual returns (uint256) {
        return 0;
    }

    /// @notice How much of `msg.value` a bootstrap may spend on the message itself.
    /// @dev All of it by default; a hub takes its fee off the top first.
    function _bootstrapSendValue(bytes32) internal virtual returns (uint256) {
        return msg.value;
    }

    /// @notice The logic an account homed on `homeChainKey` is armed with: a transmitter where
    ///         that is this chain, a receiver anywhere else.
    function _accountImplementation(bytes32 homeChainKey) internal view virtual returns (address);

    /// @notice The initializer that logic is armed with, run by delegatecall inside the
    ///         upgrade so the account is never live and uninitialized.
    /// @dev The proxy locks in the same call, and an account's own configuration is gated on
    ///      its owner, not this contract, so all provider setup must be in this calldata.
    function _accountInitializer(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls
    ) internal view virtual returns (bytes memory);

    /// @notice Grant the gateways and lock upgrades.
    ///
    /// @dev A transceiver decides which payloads are authentic, so a live upgrade key would be
    ///      a standing ability to forge any message. Locking here, inside the initializer,
    ///      leaves no window in which the key exists. The proxy's one upgrade is the
    ///      `upgradeToAndCall` that runs this initializer, authorized against the stub it
    ///      replaces.
    ///
    /// @dev Called last by `__HubTransceiverBase_init` and `__SpokeTransceiverBase_init`, not
    ///      by the binding, so no binding can ship an unlocked transceiver. A bug here is
    ///      fixed only by redeploying, which re-derives every account.
    ///
    /// @dev The only chance to name gateways (see `Roles.grantRole`). A memory array, not
    ///      loose arguments, because the divergent spokes' initializers sit near the stack
    ///      limit at `paris` without via-IR.
    function __TransceiverBase_init(address[] memory gateways) internal onlyInitializing {
        for (uint256 i; i < gateways.length; ++i) {
            if (gateways[i] != address(0)) {
                grantRole(GATEWAY_ROLE, gateways[i]);
            }
        }

        upgradesLocked = true;
        emit UpgradesLocked();
    }

    /* ============================== upgrade lock =============================== */

    /// @dev Refuses unconditionally: `__TransceiverBase_init` sets the lock and an
    ///      uninitialized transceiver has no owner to check against.
    function _authorizeUpgrade(address) internal pure override {
        revert UpgradesAreLocked();
    }

    /* ================================= inbound ================================= */

    /// @notice Whether `chainKey` reports its receiver address back rather than having it
    ///         derived. False here; a hub answers from its registry.
    /// @dev An account asks before recording a counterpart, since it holds no registry. See
    ///      `HubTransceiverBase.reportsReceiver`.
    function reportsReceiver(bytes32) public view virtual returns (bool) {
        return false;
    }

    /// @notice The funnel every binding routes an arriving message into.
    ///
    /// @dev Authentication runs here, before anything is decoded, so a binding only translates
    ///      its SDK's callback into these arguments. Who may send (`_authenticateOrigin`) and
    ///      what they may say (`_handleInbound`) vary independently between hub and spoke.
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
    /// @dev Hub: reverse-index the route, then compare against `_counterpartOn` at the
    ///      provenance bar. Spoke: compare against write-once home values.
    function _authenticateOrigin(bytes memory route, bytes memory sender)
        internal
        view
        virtual
        returns (bytes32 chainKey);

    /// @notice Act on an authenticated message.
    /// @dev Hub: a receiver report. Spoke: a bootstrap. Each decoder checks the `Envelope`
    ///      kind first, so the other shape is refused by name rather than misread.
    function _handleInbound(bytes32 chainKey, bytes calldata message) internal virtual;
}
