// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {XSafeProxy, IXSafeProxy} from "src/factories/XSafeProxy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title TransceiverBase
/// @notice Authentication, routing, and the upgrade lock. What a transceiver MAKES is not
///         here, because the two sides make different things.
///
/// @dev A SPOKE MAKES RECEIVERS. A HUB DOES NOT. Manufacturing lives in
///      `SpokeTransceiverBase` rather than in this base, so a hub does not merely decline
///      to create a receiver — it has no function that could. That matters because a
///      transmitter and its receivers are meant to share one address across chains, and an
///      address holds exactly one contract: a receiver on Ethereum would collide with the
///      transmitter that belongs there. Absence beats a revert, because there is no entry
///      point for a later change to expose.
///
///      It does not inherit `Executor` either — a transceiver has no payload of its own.
///
///      That is also why it is not an `InboundBase`. Both commitment rules live where the
///      commitment lives: `_requireCommittable` in the receiver's `commit`,
///      `_requireMatchingCalls` in its `finalize`. It keeps `OutboundBase` because it does
///      send — bootstrap messages onward, and the spoke's receiver-address report home.
///
///      It also means there is no shared slot to wedge. A payload that can never execute
///      strands itself at its own transmitter's receiver, which is one-per-transmitter by
///      construction, and blocks nobody.
///
/// @dev IT INHERITS NO OWNERSHIP. Privileged operations go through `_checkAdmin`, which
///      the concrete contract satisfies from whatever authority it already has. That is
///      what lets a protocol binding — an OApp, a Hyperlane mailbox client — join at the
///      concrete contract without its `Ownable` colliding with one declared here.
///
/// @dev THIS BASE IS THE SYMMETRIC HALF, AND ONLY THAT. Cloning, initialization, and the
///      upgrade lock work identically wherever the transceiver is deployed. Everything
///      about ADDRESSING a counterpart does not, because the two sides have opposite
///      cardinality: Ethereum's hub has N counterparts and needs a registry to tell them
///      apart, while a spoke has exactly one — Ethereum — and knows it at compile time.
///      That asymmetry is isolated behind `_route`, so a spoke never carries a registry
///      pointer, a provenance dial, or a routing table it has no use for.
///
/// @dev ONE RECEIVER PER TRANSMITTER, PER DESTINATION. The CREATE2 salt is the
///      transmitter and nothing else, so a transmitter's receiver address is fixed for
///      the life of the protocol: known before the first message, unchanged after the
///      thousandth. Nothing about the payload is in the salt — that would mint a new
///      receiver per message and throw away the state a receiver accumulates.
abstract contract TransceiverBase is OutboundBase, Initializable, UUPSUpgradeable {
    /// Once true, no further implementation change is possible. One-way.
    bool public upgradesLocked;

    /// @notice The initcode hash every xsafe account deploys from — one constant, on
    ///         every chain, for transmitters and receivers alike.
    /// @dev Exposed so Ethereum can record it and reproduce these addresses without
    ///      deploying anything. See `XSafeProxy` for why it has no constructor arguments.
    bytes32 public constant XSAFE_PROXY_INIT_CODE_HASH =
        keccak256(type(XSafeProxy).creationCode);

    event UpgradesLocked();
    /// @dev Owner and account are indexed; the salt rides in the data. Three indexed
    ///      fields would exhaust the topic budget for a value nobody filters on — an
    ///      indexer wants "this owner's accounts" or "this address", not "everyone who
    ///      chose salt 7".
    event XSafeAccountCreated(
        address indexed owner, address indexed account, bytes32 salt
    );

    error ZeroTransmitterCommit();
    error UpgradesAreLocked();
    error ZeroOwner();
    error ZeroRoute();
    /// @dev A route names the chain every message to it is addressed by. Re-pointing one
    ///      would redirect every send to that destination at once, so it is a redeploy
    ///      rather than a config edit.
    error RouteAlreadySet(bytes32 chainKey);
    error NoRouteFor(bytes32 chainKey);
    /// @dev Two chains sharing one provider id would let an inbound message be attributed
    ///      to the wrong source. A forgery primitive, not a config mistake.
    error RouteInUse(bytes32 routeKey);
    error UnknownRoute();
    /// @dev The caller is not the account `(owner, salt)` resolves to, so it is asking the
    ///      protocol to stand up somebody else's account somewhere else.
    error NotTheAccount(address owner, bytes32 salt, address caller);
    error XSafeAccountExists(address owner, bytes32 salt, address account);
    error NoAccountImplementation();

    /* ================================== routing ================================ */

    /// chainKey => the message provider's OWN name for that chain, opaque.
    ///
    /// @dev THE ONLY PLACE A PROVIDER-NATIVE ID LIVES ON THIS SIDE. Everything above
    ///      speaks chainKeys, which every VM has; a provider needs its own identifier for
    ///      a chain, which nothing else in the protocol can derive. One owner-set mapping
    ///      is the whole translation layer.
    ///
    /// @dev IT IS ON THE TRANSCEIVER RATHER THAN THE REGISTRY BECAUSE THIS IS WHO SENDS.
    ///      A registry read would put a second shared contract in the path of every send
    ///      and give a compromised one the ability to misroute a payload — and on the
    ///      execute-on-arrival path there is no commitment binding the destination, so a
    ///      wrong id means the payload runs on the wrong chain. Keeping it here means the
    ///      contract that sends is the contract that knows where.
    mapping(bytes32 => bytes) private _routes;
    /// keccak256(route) => chainKey. The reverse direction, which is not optional:
    /// inbound, a provider hands over a source id and this contract has to turn it back
    /// into a chain.
    ///
    /// @dev MAINTAINED IN THE SAME SETTER, because two setters is how the two directions
    ///      drift apart. It is injective by construction: two chainKeys sharing one route
    ///      would let an inbound message be attributed to the wrong source chain, which is
    ///      a forgery primitive rather than a config mistake, so a collision reverts.
    mapping(bytes32 => bytes32) private _chainKeyOfRoute;

    event RouteSet(bytes32 indexed chainKey, bytes route);

    /// @notice Teach this transceiver its provider's name for a destination. WRITE-ONCE.
    ///
    /// @dev Re-writing the SAME route is a no-op, so a replayed configuration transaction
    ///      is not a failure. A DIFFERENT one reverts: it would redirect every message to
    ///      that destination at once, which is a redeploy rather than an edit.
    ///
    /// @dev It is `bytes` rather than a `uint32`, because the shape is the provider's
    ///      business — a LayerZero eid, a Hyperlane domain, a Wormhole uint16, a CCIP
    ///      uint64 selector, an Axelar chain-name string. A concrete binding wraps this in
    ///      a typed setter; see `LzHubTransceiver.setEid`.
    function setRoute(bytes32 chainKey, bytes memory route) public onlyAdmin {
        if (chainKey == bytes32(0)) revert NoDestination();
        if (route.length == 0) revert ZeroRoute();

        bytes memory existing = _routes[chainKey];
        if (existing.length != 0) {
            if (keccak256(existing) != keccak256(route)) revert RouteAlreadySet(chainKey);
            return;
        }

        bytes32 routeKey = keccak256(route);
        bytes32 held = _chainKeyOfRoute[routeKey];
        if (held != bytes32(0) && held != chainKey) revert RouteInUse(routeKey);

        _routes[chainKey] = route;
        _chainKeyOfRoute[routeKey] = chainKey;
        emit RouteSet(chainKey, route);
    }

    /// @notice The chain a provider's own id refers to. The inbound direction.
    /// @dev Resolved once, here, at the edge — nothing above this contract speaks a
    ///      provider's language.
    function chainKeyOfRoute(bytes memory route) public view returns (bytes32 chainKey) {
        chainKey = _chainKeyOfRoute[keccak256(route)];
        if (chainKey == bytes32(0)) revert UnknownRoute();
    }

    /// @notice The provider's name for a chain. Reverts when unset, because an
    ///         unconfigured id and an id of zero are different states and a send that
    ///         confused them would go into the void.
    function routeFor(bytes32 chainKey) public view returns (bytes memory route) {
        route = _routes[chainKey];
        if (route.length == 0) revert NoRouteFor(chainKey);
    }

    function hasRoute(bytes32 chainKey) external view returns (bool) {
        return _routes[chainKey].length != 0;
    }

    /* ============================ account manufacture ========================== */

    /// @notice The salt an owner's account deploys at, on every chain.
    ///
    /// @dev THE OWNER AND A SALT THEY CHOOSE. The owner is what makes the address mean the
    ///      same thing on both sides — a CREATE2 address cannot be derived from itself, so
    ///      the transmitter's own address could never serve, and the owner is the one
    ///      identity Ethereum and the destination both name. The salt is what lets one
    ///      owner hold more than one account: one per purpose, per counterparty, per
    ///      mandate, each with its own address on every chain.
    ///
    /// @dev IT IS HASHED, NOT CONCATENATED. `abi.encode` is fixed-width, so no
    ///      `(owner, salt)` pair can collide with another by sliding bytes across the
    ///      boundary — which `encodePacked` over an address and a bytes32 would not
    ///      guarantee if either ever became variable-length.
    function accountSalt(address owner, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt));
    }

    /// @notice Where an owner's account lives on this chain — before it exists.
    /// @dev Identical on every chain sharing Ethereum's CREATE2 formula, because all three
    ///      inputs are: this contract's address (hub and spoke share one), the
    ///      `(owner, salt)` pair, and a constant initcode.
    function predictXSafeAccount(address owner, bytes32 salt)
        public
        view
        returns (address)
    {
        return Create2.computeAddress(
            accountSalt(owner, salt), XSAFE_PROXY_INIT_CODE_HASH, address(this)
        );
    }

    /// @notice Deploy an owner's account and hand it the logic this side of the protocol
    ///         installs.
    ///
    /// @dev ONE FUNCTION, TWO OUTCOMES, AND THE ADDRESS DOES NOT KNOW THE DIFFERENCE. A hub
    ///      installs a transmitter, a spoke installs a receiver, and both deploy the same
    ///      argument-free proxy at the same salt from the same address — so an owner's
    ///      transmitter on Ethereum and their receiver on Base are one address. What
    ///      diverges is `_accountImplementation`, which the derivation never sees.
    ///
    /// @dev DEPLOY, ARM, AND LOCK IN ONE CALL. `XSafeProxy` offers no way to install logic
    ///      without surrendering the upgrade key in the same call, so there is no reachable
    ///      state in which an account has real logic and a live key. See `XSafeProxy`.
    function _createXSafeAccount(address owner, bytes32 salt, Call[] memory calls)
        internal
        returns (address account)
    {
        if (owner == address(0)) revert ZeroOwner();

        address implementation = _accountImplementation();
        if (implementation == address(0)) revert NoAccountImplementation();

        account = predictXSafeAccount(owner, salt);
        if (account.code.length != 0) revert XSafeAccountExists(owner, salt, account);

        Create2.deploy(0, accountSalt(owner, salt), type(XSafeProxy).creationCode);
        IXSafeProxy(account).upgradeInitializeAndLock(
            implementation, _accountInitializer(owner, salt, calls)
        );

        emit XSafeAccountCreated(owner, account, salt);
    }

    /// @notice Stand this account up on a chain that has none, and carry its payload.
    ///
    /// @dev PERMISSIONLESS, AND THE ARGUMENT IS THE ADDRESS. The only reachable outcome is
    ///      an account keyed to `(owner, salt)` — and the caller must BE that account, so
    ///      the only account anyone can bootstrap is the one that already answers to them.
    ///      Nobody gains anything by paying to create somebody else's.
    ///
    /// @dev THE PAIR IS CHECKED, NOT TRUSTED. `msg.sender` must be what
    ///      `predictXSafeAccount(owner, salt)` resolves to. That is what lets the owner and
    ///      salt travel in the message without a caller being able to claim another
    ///      account's identity — the address on this chain proves the pair.
    ///
    /// @dev THE ONLY CALLER OF `_requireRoutable`, and therefore the only place
    ///      `minCounterpartProvenance` is enforced. A bar on the first message to a chain
    ///      rather than on every send: once an account exists there, its own sends go
    ///      straight to it and never reach this contract again.
    function bootstrap(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        Call[] calldata calls,
        bytes calldata providerData
    ) external payable {
        if (predictXSafeAccount(owner, salt) != msg.sender) {
            revert NotTheAccount(owner, salt, msg.sender);
        }

        // The provenance bar lives inside this check: an under-graded counterpart, or an
        // unconfigured route, reverts before anything crosses.
        _requireRoutable(destinationChainKey);

        _dispatch(
            destinationChainKey, Envelope.encodeBootstrap(owner, salt, calls), providerData
        );
    }

    /// @notice `bootstrap`, for a destination whose calls this chain cannot express.
    ///
    /// @dev THE SAME CHECKS, THE OTHER FORM. Which one a caller may use is decided by the
    ///      destination's chain type, and enforced where that type is known — at the
    ///      transmitter, which holds the ERC-7930 envelope. This contract sees only a
    ///      chainKey, which is a hash and cannot be asked what chain type it came from.
    function bootstrapElements(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        bytes[] calldata elements,
        bytes calldata providerData
    ) external payable {
        if (predictXSafeAccount(owner, salt) != msg.sender) {
            revert NotTheAccount(owner, salt, msg.sender);
        }

        _requireRoutable(destinationChainKey);

        _dispatch(
            destinationChainKey,
            Envelope.encodeBootstrapElements(owner, salt, elements),
            providerData
        );
    }

    /// @notice The logic this side installs. Hub: a transmitter. Spoke: a receiver.
    function _accountImplementation() internal view virtual returns (address);

    /// @notice The initializer call that logic is armed with, run by delegatecall inside
    ///         the upgrade so the account is never live and uninitialized.
    ///
    /// @dev THIS IS WHERE PROVIDER SETUP HAS TO HAPPEN, and there is no second chance. The
    ///      proxy locks in the same call that arms it, and an account's own configuration
    ///      — a peer table, a delegate — is gated on its OWNER, which this contract is not.
    ///      So a transceiver has no authority over an account after creating it, and
    ///      anything the provider needs configured must be folded into this calldata.
    ///
    ///      It is `virtual` all the way down for exactly that reason: a protocol binding
    ///      overrides it to build an initializer carrying whatever its SDK requires.
    function _accountInitializer(address owner, bytes32 salt, Call[] memory calls)
        internal
        view
        virtual
        returns (bytes memory);

    /// @notice Bind the transceiver to the xsafe msig.
    /// @dev The proxy starts on Nick's factory implementation with the deployer as owner,
    ///      is upgraded to the real transceiver, and then `lockUpgrades` is called. See
    ///      that function for why the lock exists.
    function __TransceiverBase_init() internal onlyInitializing {
        __UUPSUpgradeable_init();
    }

    /* ============================== authorization ============================== */

    /// @notice The authority for privileged operations on this transceiver.
    ///
    /// @dev DECLARED, NOT IMPLEMENTED, AND THAT IS THE POINT. Inheriting an ownership
    ///      system here would make this base impossible to combine with a message
    ///      provider's own SDK base — LayerZero's `OAppCore` is `Ownable`, Hyperlane's
    ///      mailbox client has its own owner — without the concrete contract carrying two
    ///      of them. Two owners on one contract is not a style problem: it means a
    ///      transceiver whose upgrades are "locked" behind one authority can still be
    ///      reconfigured through the other.
    ///
    ///      So the base states the REQUIREMENT and the concrete contract satisfies it from
    ///      whatever authority it already has — `_checkOwner()` for OApp's `Ownable` or
    ///      `OwnableUpgradeable`, a role check for `AccessControl`, a raw msig comparison.
    ///      That is what lets `LzTransceiver` be an OApp without `OApp` appearing anywhere
    ///      in this file.
    function _checkAdmin() internal view virtual;

    modifier onlyAdmin() {
        _checkAdmin();
        _;
    }

    /* ================================= routing ================================= */

    /// @notice THE SEAM BETWEEN HUB AND SPOKE, one half: where the counterpart lives.
    ///
    /// @dev A hub answers this out of the registry, applying a provenance bar to the
    ///      counterpart's claimed location. A spoke answers it from a stored constant and
    ///      rejects every key but Ethereum's. Protocol code above calls the same function
    ///      either way.
    ///
    ///      The counterpart is NOT assumed to be at this contract's own address. That
    ///      holds for most EVM chains — same factory, same salt, same initcode, same
    ///      address — but not for zkSync or Tron, whose CREATE2 formulas differ, and
    ///      obviously not for Solana or the Move chains. So it is raw bytes in that
    ///      chain's own format: a 32-byte key cannot be turned back into a Solana pubkey
    ///      or a Move type tag.
    function _counterpartOn(bytes32 chainKey) internal view virtual returns (bytes memory);

    /// @notice THE SEAM, other half: the message provider's own name for a chain — a
    ///         LayerZero eid, a Hyperlane domain, a Wormhole chain id.
    ///
    /// @dev SEPARATE FROM `_counterpartOn` ON PURPOSE. The two are configured
    ///      independently and can be missing independently: a chain can have a resolved
    ///      counterpart with no eid set yet, or an eid with the counterpart still
    ///      unresolved. Folding them into one lookup would make a half-wired destination
    ///      un-inspectable — you could not read the part that IS configured to find out
    ///      which part is not.
    /// @dev The default answers from this contract's own write-once table. A spoke
    ///      overrides it, because its one destination is a compile-time literal rather
    ///      than something anyone configures.
    function _routeTo(bytes32 chainKey) internal view virtual returns (bytes memory) {
        return routeFor(chainKey);
    }

    /// @notice Both halves at once, for the send path, which needs each of them.
    /// @notice Revert unless this transceiver can reach `chainKey` — a counterpart it
    ///         trusts at its provenance bar, and a route to address it by.
    ///
    /// @dev IT IS CALLED FOR THE REVERT, AND THE NAME SAYS SO. Both lookups throw away
    ///      their values here; what matters is that `_counterpartOn` refuses a counterpart
    ///      below `minCounterpartProvenance` and `_routeTo` refuses an unconfigured
    ///      destination. A function returning values nobody reads invites someone to
    ///      remove the "unused" call and take the check with it.
    ///
    /// @dev The adapter reads both again when it sends. That is a second lookup rather
    ///      than a threaded parameter on purpose: it keeps `_sendMessage` to three
    ///      arguments, and both reads are `view` against this contract's own storage.
    function _requireRoutable(bytes32 chainKey) internal view {
        _counterpartOn(chainKey);
        _routeTo(chainKey);
    }

    /// @notice Where this transceiver's counterpart lives on `chainKey`.
    function counterpartOn(bytes32 chainKey) public view returns (bytes memory) {
        return _counterpartOn(chainKey);
    }

    /// @notice The message provider's own identifier for `chainKey`.
    function routeTo(bytes32 chainKey) public view returns (bytes memory) {
        return _routeTo(chainKey);
    }

    /* ============================== upgrade lock =============================== */

    /// @notice Permanently disable upgrades. IRREVERSIBLE.
    /// @dev The proxy has to be upgradeable to get off the Arachnid/Nick's-factory
    ///      implementation it is created with. Once the real transceiver is in place that
    ///      capability is pure downside: a transceiver is the contract that decides which
    ///      cross-chain payloads are authentic, so a live upgrade key is a standing
    ///      ability to forge one. Locking converts "we promise not to" into "we cannot".
    function lockUpgrades() external onlyAdmin {
        upgradesLocked = true;
        emit UpgradesLocked();
    }

    /// @dev Gate for UUPS. Owner-only, and refused outright once locked.
    function _authorizeUpgrade(address) internal override onlyAdmin {
        if (upgradesLocked) revert UpgradesAreLocked();
    }

    /* =========================== commit and finalize =========================== */

    /* ================================= inbound ================================= */

    /// @notice The one funnel every protocol adapter routes an arriving message into.
    ///
    /// @dev AUTHENTICATION IS NOT THE ADAPTER'S JOB. It runs here, before anything is
    ///      decoded, so a new protocol binding cannot ship without it — the adapter's only
    ///      responsibility is translating its SDK's callback into these three arguments.
    ///      A transceiver decides which cross-chain payloads are authentic; leaving that
    ///      check to be re-implemented per provider is how one provider ends up without it.
    ///
    /// @dev IT SPLITS INTO TWO VIRTUALS BECAUSE TWO THINGS VARY INDEPENDENTLY. Who may
    ///      send varies by CARDINALITY — a spoke compares against constants, a hub resolves
    ///      N origins through the registry. What they may say varies by DIRECTION — a spoke
    ///      receives commitments, a hub receives receiver reports. Folding both into one
    ///      overridable hook would let a subclass get the second right and the first wrong.
    ///
    /// @param route   The provider's own id for the source chain, as it reported it.
    /// @param sender  The counterpart's address on that chain, in that chain's own format.
    /// @param message The body — see `Envelope`.
    function _onInbound(bytes memory route, bytes memory sender, bytes calldata message)
        internal
    {
        bytes32 chainKey = _authenticateOrigin(route, sender);
        _handleInbound(chainKey, message);
    }

    /// @notice Establish which chain this came from, and refuse it if the sender is not
    ///         that chain's counterpart.
    /// @dev Hub: reverse-index the route, then compare against the registry's counterpart
    ///      at the provenance bar. Spoke: compare against two constants.
    function _authenticateOrigin(bytes memory route, bytes memory sender)
        internal
        view
        virtual
        returns (bytes32 chainKey);

    /// @notice Act on an authenticated message.
    /// @dev Hub: a receiver report. Spoke: a commitment. Each side decodes exactly one
    ///      shape, which is why `Envelope` carries no type tag.
    function _handleInbound(bytes32 chainKey, bytes calldata message) internal virtual;
}
