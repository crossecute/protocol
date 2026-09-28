// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Call} from "src/messaging/Call.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {ICancel, ICommitFinalize, InboundBase} from "src/messaging/inbound/InboundBase.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {CrossProxy, ICrossProxy} from "src/account/CrossProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title TransceiverBase
/// @notice Authentication, routing, manufacture, and the upgrade lock: the half that is
///         identical wherever a transceiver is deployed.
///
/// @dev Only a spoke makes receivers; manufacture lives in `SpokeTransceiverBase`, so a hub
///      has no function that could. A transmitter and its receivers share one address, so a
///      receiver on the home chain would collide with the transmitter there.
///
/// @dev An `InboundBase`, so a bootstrap can be deferred: its payload may arrive as
///      `commit(hash)` and be finalized later by anyone willing to pay, running
///      `bootstrapInbound` as a self-call. `_checkCommitter` admits only this contract.
///
/// @dev Not a `ReceiverBase`: no `sourceTransmitter` and no `execute`, and `cancel` is
///      self-call only, since a transceiver is shared by every owner on its chain.
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
/// @dev An account's CREATE2 salt is `(owner, salt)` and nothing else, so one transmitter has
///      one receiver per destination, at an address fixed before the first message.
abstract contract TransceiverBase is Initializable, OutboundBase, InboundBase, ICancel, UUPSUpgradeable {
    /// Once true, no further implementation change is possible. One-way.
    bool public upgradesLocked;

    /// @notice The initcode hash every crossecute account deploys from, for transmitters and
    ///         receivers alike. See `CrossProxy` for why it has no constructor arguments.
    /// @dev An input to Ethereum's CREATE2 formula only. zkSync deploys from a zksolc artifact
    ///      hash instead; see `predictCrossAccount`.
    bytes32 public constant CROSS_PROXY_INIT_CODE_HASH = keccak256(type(CrossProxy).creationCode);

    event UpgradesLocked();
    event CrossAccountCreated(address indexed owner, address indexed account, bytes32 salt);

    error UpgradesAreLocked();
    error ZeroOwner();
    /// @dev The caller is not the account `(owner, salt)` resolves to.
    error NotTheAccount(address owner, bytes32 salt, address caller);
    error CrossAccountExists(address owner, bytes32 salt, address account);
    /// @dev `predictCrossAccount` and `_deployAccount` disagree: a spoke on a diverging chain
    ///      overrode one and not the other.
    error AccountAddressMismatch(address predicted, address deployed);
    error NoAccountImplementation();
    /// @dev Reachable only from a payload this contract is executing, which arrived through an
    ///      authenticated delivery.
    error NotSelfCall(address caller);

    /* ================================== routing ================================ */

    /// @dev Path B's record, since a transceiver is not an ERC-7786 gateway source and emits
    ///      no `MessageSent`. `(chainKey, owner, salt)` identifies the account.
    event BootstrapSent(bytes32 indexed destinationChainKey, address indexed owner, bytes32 salt);

    /* ============================ account manufacture ========================== */

    /// @notice The salt an owner's account deploys at, on every chain.
    /// @dev The owner is the identity both chains name; the salt lets one owner hold several
    ///      accounts. `abi.encode` is fixed-width, so no two pairs collide.
    function accountSalt(address owner, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt));
    }

    /// @notice Where an owner's account lives on this chain, before it exists.
    /// @dev Ethereum's CREATE2, identical wherever the formula holds since all three inputs
    ///      are: this address (hub and spoke share one), the salt, and a constant initcode.
    ///      zkSync and Tron derive differently, so a spoke there overrides this and
    ///      `_deployAccount` together; `_createCrossAccount` checks the two agree.
    function predictCrossAccount(address owner, bytes32 salt) public view virtual returns (address) {
        return Create2.computeAddress(accountSalt(owner, salt), CROSS_PROXY_INIT_CODE_HASH, address(this));
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
    function _createCrossAccount(address owner, bytes32 salt, Call[] memory calls) internal returns (address account) {
        if (owner == address(0)) revert ZeroOwner();

        address implementation = _accountImplementation();
        if (implementation == address(0)) revert NoAccountImplementation();

        account = predictCrossAccount(owner, salt);
        if (account.code.length != 0) revert CrossAccountExists(owner, salt, account);

        address deployed = _deployAccount(accountSalt(owner, salt));
        if (deployed != account) revert AccountAddressMismatch(account, deployed);

        ICrossProxy(account).upgradeInitializeAndLock(implementation, _accountInitializer(owner, salt, calls));

        emit CrossAccountCreated(owner, account, salt);
    }

    /// @notice Stand an account up on a chain that has none, and carry its payload.
    ///
    /// @dev Callable only by the account `(owner, salt)` resolves to, which is what lets the
    ///      owner and salt travel in the message without a caller claiming another identity.
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
        if (predictCrossAccount(owner, salt) != msg.sender) {
            revert NotTheAccount(owner, salt, msg.sender);
        }

        // The provenance bar lives inside this check: an under-graded counterpart, or an
        // unconfigured route, reverts before anything crosses.
        _requireRoutable(destinationChainKey);

        emit BootstrapSent(destinationChainKey, owner, salt);
        _sendMessage(
            _recipientOn(destinationChainKey),
            Envelope.encodeBootstrap(owner, salt, calls),
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
        if (predictCrossAccount(owner, salt) != msg.sender) {
            revert NotTheAccount(owner, salt, msg.sender);
        }

        _requireRoutable(destinationChainKey);

        emit BootstrapSent(destinationChainKey, owner, salt);
        _sendMessage(
            _recipientOn(destinationChainKey),
            Envelope.encodeBootstrapElements(owner, salt, elements),
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
        return _quoteMessage(
            _recipientOn(destinationChainKey), Envelope.encodeBootstrap(owner, salt, calls), attributes
        ) + _bootstrapSurcharge(destinationChainKey);
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
        return _quoteMessage(
            _recipientOn(destinationChainKey), Envelope.encodeBootstrapElements(owner, salt, elements), attributes
        ) + _bootstrapSurcharge(destinationChainKey);
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

    /// @notice The logic this side installs. Hub: a transmitter. Spoke: a receiver.
    function _accountImplementation() internal view virtual returns (address);

    /// @notice The initializer that logic is armed with, run by delegatecall inside the
    ///         upgrade so the account is never live and uninitialized.
    /// @dev The proxy locks in the same call, and an account's own configuration is gated on
    ///      its owner, not this contract, so all provider setup must be in this calldata.
    function _accountInitializer(address owner, bytes32 salt, Call[] memory calls)
        internal
        view
        virtual
        returns (bytes memory);

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
    function _authorizeUpgrade(address) internal view override {
        revert UpgradesAreLocked();
    }

    /* ================================= inbound ================================= */

    /// @notice Who may approve a hash here: only a payload this contract is executing.
    /// @dev Narrower than a receiver, which also admits its transmitter; a transceiver has no
    ///      single party to admit.
    function _checkCommitter() internal view override {
        if (msg.sender != address(this)) revert NotSelfCall(msg.sender);
    }

    /// @notice Authenticate an ERC-7930 sender envelope: the chain half is the route, the
    ///         address half the sender, both checked by `_authenticateOrigin`.
    function _authenticateSender(bytes calldata sender) internal view override {
        _authenticateOrigin(Erc7930.toChainIdentifier(sender), Erc7930.parseStrict(sender).addr);
    }

    /// @notice Whether `chainKey` reports its receiver address back rather than having it
    ///         derived. False here; a hub answers from its registry.
    /// @dev An account asks before recording a counterpart, since it holds no registry. See
    ///      `HubTransceiverBase.reportsReceiver`.
    function reportsReceiver(bytes32) public view virtual returns (bool) {
        return false;
    }

    /// @notice What an arriving payload may call: `commit` and `cancel` on this contract, and
    ///         on a spoke `bootstrapInbound`.
    ///
    /// @dev A transceiver authenticates every inbound message and deploys every account, so an
    ///      unconstrained `_execute` would give an authenticated counterpart its whole address.
    ///      A payload could self-call `HubTransceiverBase.onDestinationReceiver` with any
    ///      chainKey and pin an account's receiver on another chain, which the account never
    ///      unpins. It could also send a spoke's report float anywhere. Both allowed targets
    ///      are `address(this)` and non-payable, so value-carrying calls revert.
    function isAllowed(address target, bytes4 selector) public view virtual override returns (bool) {
        return
            target == address(this)
                && (selector == ICommitFinalize.commit.selector || selector == ICancel.cancel.selector);
    }

    /// @notice Withdraw an approval this transceiver is holding.
    /// @dev Gated like `commit`: only a payload from the authenticated counterpart reaches it.
    ///      Without it an approved bootstrap could never be withdrawn, and whoever supplied the
    ///      array to the permissionless `finalize` would choose when it ran.
    function cancel(bytes32 commitment_) external virtual override {
        _checkCommitter();
        _cancel(commitment_);
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
    /// @dev Hub: a receiver report. Spoke: a bootstrap. Each side decodes one shape, so
    ///      `Envelope` carries no type tag.
    function _handleInbound(bytes32 chainKey, bytes calldata message) internal virtual;
}
