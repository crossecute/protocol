// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {CrossProxy, ICrossProxy} from "src/factories/CrossProxy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title TransceiverBase
/// @notice Authentication, routing, manufacture, and the upgrade lock: the half that is
///         identical wherever a transceiver is deployed.
///
/// @dev A SPOKE MAKES RECEIVERS. A HUB DOES NOT. Manufacturing lives in
///      `SpokeTransceiverBase`, so a hub does not merely decline to create a receiver: it
///      has no function that could. That matters because a transmitter and its receivers
///      share one address, and an address holds one contract, so a receiver on the home
///      chain would collide with the transmitter that belongs there. Absence beats a revert,
///      because there is no entry point for a later change to expose.
///
/// @dev IT IS NOT AN `Executor` AND NOT A `ReceiverBase`. A transceiver has no payload of its
///      own, and both commitment rules live where the commitment lives. It keeps
///      `OutboundBase` because it does send: bootstrap messages onward, and the spoke's
///      receiver-address report home. It also means there is no shared slot to wedge: a
///      payload that can never execute strands itself at its own transmitter's receiver,
///      which is one-per-transmitter by construction, and blocks nobody.
///
/// @dev IT INHERITS NO OWNERSHIP. Privileged operations go through `_checkAdmin`, which the
///      concrete contract satisfies from whatever authority it already has. That is what
///      lets a protocol binding join at the concrete contract without its `Ownable`
///      colliding with one declared here.
///
/// @dev EVERYTHING ASYMMETRIC IS BEHIND `_counterpartOn` AND `_routeTo`, because the two
///      sides have opposite cardinality: the hub has N counterparts and needs a registry to
///      tell them apart, while a spoke has exactly one and is told which at deployment. So a
///      spoke never carries a registry pointer, a provenance dial, or a routing table it has
///      no use for.
///
/// @dev ONE RECEIVER PER TRANSMITTER, PER DESTINATION. The CREATE2 salt is `(owner, salt)`
///      and nothing else, so an account's address is fixed for the life of the protocol:
///      known before the first message, unchanged after the thousandth. Nothing about the
///      payload is in the salt, which would mint a new receiver per message and throw away
///      the state a receiver accumulates.
abstract contract TransceiverBase is OutboundBase, Initializable, UUPSUpgradeable {
    /// Once true, no further implementation change is possible. One-way.
    bool public upgradesLocked;

    /// @notice The initcode hash every crossecute account deploys from: one constant, on
    ///         every chain, for transmitters and receivers alike.
    /// @dev Exposed so the hub can record it and reproduce these addresses without deploying
    ///      anything. See `CrossProxy` for why it has no constructor arguments.
    bytes32 public constant CROSS_PROXY_INIT_CODE_HASH =
        keccak256(type(CrossProxy).creationCode);

    event UpgradesLocked();
    /// @dev Owner and account are indexed; the salt rides in the data. Three indexed fields
    ///      would exhaust the topic budget for a value nobody filters on: an indexer wants
    ///      "this owner's accounts" or "this address", not "everyone who chose salt 7".
    event CrossAccountCreated(
        address indexed owner, address indexed account, bytes32 salt
    );

    error ZeroTransmitterCommit();
    error UpgradesAreLocked();
    error ZeroOwner();
    error ZeroRoute();
    /// @dev Re-pointing a route would redirect every message to that destination at once, so
    ///      it is a redeploy rather than a config edit.
    error RouteAlreadySet(bytes32 chainKey);
    error NoRouteFor(bytes32 chainKey);
    /// @dev Two chains sharing one identifier would let an inbound message be attributed to
    ///      the wrong source: a forgery primitive, not a config mistake.
    error RouteInUse(bytes32 routeKey);
    error UnknownRoute();
    /// @dev The caller is not the account `(owner, salt)` resolves to, so it is asking the
    ///      protocol to stand up somebody else's account somewhere else.
    error NotTheAccount(address owner, bytes32 salt, address caller);
    error CrossAccountExists(address owner, bytes32 salt, address account);
    error NoAccountImplementation();

    /* ================================== routing ================================ */

    /// chainKey => that chain's canonical ERC-7930 chain identifier.
    ///
    /// @dev IT IS ON THE TRANSCEIVER RATHER THAN THE REGISTRY BECAUSE THIS IS WHO SENDS. A
    ///      registry read would put a second shared contract in the path of every send and
    ///      give a compromised one the ability to misroute a payload; on the
    ///      execute-on-arrival path there is no commitment binding the destination, so a
    ///      wrong id means the payload runs on the wrong chain.
    mapping(bytes32 => bytes) private _routes;
    /// keccak256(route) => chainKey. The inbound direction, which is not optional: a provider
    /// hands over a source id and this contract has to turn it back into a chain.
    ///
    /// @dev MAINTAINED IN THE SAME SETTER, because two setters is how the two directions
    ///      drift apart. It is injective by construction, and a collision reverts.
    mapping(bytes32 => bytes32) private _chainKeyOfRoute;

    event RouteSet(bytes32 indexed chainKey, bytes route);
    /// @dev Path B's own record, replacing the generic `Dispatched` it used to share with
    ///      path A. A transceiver is not an ERC-7786 gateway source, so nothing here emits
    ///      `MessageSent`, and naming the pair is more use to an operator than hashing it:
    ///      `(chainKey, owner, salt)` is what an account IS, and it is what the registry slot
    ///      on the return leg is keyed by.
    event BootstrapSent(bytes32 indexed destinationChainKey, address indexed owner, bytes32 salt);

    /// @notice Teach this transceiver how a destination is named. WRITE-ONCE.
    ///
    /// @dev THE ROUTE IS THE CHAIN'S ERC-7930 IDENTIFIER, not a provider's private id for it.
    ///      That is what ERC-7786 removed the need for: a gateway is told the chain by the
    ///      recipient. It also makes the reverse index correct by construction, since
    ///      `keccak256(identifier)` IS the chainKey. A binding wraps this in a typed setter
    ///      only where it keeps a provider-native value of its own.
    ///
    /// @dev Re-writing the SAME route is a no-op, so a replayed configuration transaction is
    ///      not a failure. A DIFFERENT one reverts.
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

    /// @notice The chain a route refers to. The inbound direction, resolved once, at the edge.
    function chainKeyOfRoute(bytes memory route) public view returns (bytes32 chainKey) {
        chainKey = _chainKeyOfRoute[keccak256(route)];
        if (chainKey == bytes32(0)) revert UnknownRoute();
    }

    /// @notice How a chain is named here. Reverts when unset, because an unconfigured id and
    ///         an id of zero are different states and a send that confused them would go into
    ///         the void.
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
    ///      same thing on both sides: a CREATE2 address cannot be derived from itself, so the
    ///      account's own address could never serve, and the owner is the one identity the
    ///      home chain and the destination both name. The salt is what lets one owner hold
    ///      more than one account: one per purpose, per counterparty, per mandate.
    ///
    /// @dev IT IS HASHED, NOT CONCATENATED. `abi.encode` is fixed-width, so no `(owner, salt)`
    ///      pair can collide with another by sliding bytes across the boundary.
    function accountSalt(address owner, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt));
    }

    /// @notice Where an owner's account lives on this chain, before it exists.
    /// @dev Identical on every chain sharing Ethereum's CREATE2 formula, because all three
    ///      inputs are: this contract's address (hub and spoke share one), the `(owner, salt)`
    ///      pair, and a constant initcode.
    function predictCrossAccount(address owner, bytes32 salt)
        public
        view
        returns (address)
    {
        return Create2.computeAddress(
            accountSalt(owner, salt), CROSS_PROXY_INIT_CODE_HASH, address(this)
        );
    }

    /// @notice Deploy an owner's account and arm it with the logic this side installs.
    ///
    /// @dev ONE FUNCTION, TWO OUTCOMES, AND THE ADDRESS DOES NOT KNOW THE DIFFERENCE. A hub
    ///      installs a transmitter, a spoke installs a receiver, and both deploy the same
    ///      argument-free proxy at the same salt from the same address. What diverges is
    ///      `_accountImplementation`, which the derivation never sees.
    ///
    /// @dev DEPLOY, ARM, AND LOCK IN ONE CALL. `CrossProxy` offers no way to install logic
    ///      without surrendering the upgrade key in the same call, so there is no reachable
    ///      state in which an account has real logic and a live key.
    function _createCrossAccount(address owner, bytes32 salt, Call[] memory calls)
        internal
        returns (address account)
    {
        if (owner == address(0)) revert ZeroOwner();

        address implementation = _accountImplementation();
        if (implementation == address(0)) revert NoAccountImplementation();

        account = predictCrossAccount(owner, salt);
        if (account.code.length != 0) revert CrossAccountExists(owner, salt, account);

        Create2.deploy(0, accountSalt(owner, salt), type(CrossProxy).creationCode);
        ICrossProxy(account).upgradeInitializeAndLock(
            implementation, _accountInitializer(owner, salt, calls)
        );

        emit CrossAccountCreated(owner, account, salt);
    }

    /// @notice Stand an account up on a chain that has none, and carry its payload.
    ///
    /// @dev PERMISSIONLESS, AND THE ARGUMENT IS THE ADDRESS. `msg.sender` must be what
    ///      `predictCrossAccount(owner, salt)` resolves to, so the only account anyone can
    ///      bootstrap is the one that already answers to them, and nobody gains anything by
    ///      paying to create somebody else's. That check is also what lets the owner and salt
    ///      travel in the message without a caller claiming another account's identity.
    ///
    /// @dev THE ONLY CALLER OF `_requireRoutable`, and therefore the only place
    ///      `minCounterpartProvenance` is enforced: a bar on the first message to a chain
    ///      rather than on every send, since once an account exists there its own sends go
    ///      straight to it and never reach this contract again.
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
            attributes
        );
    }

    /// @notice `bootstrap`, for a destination whose calls this chain cannot express.
    /// @dev THE SAME CHECKS, THE OTHER FORM. Which one a caller may use is decided by the
    ///      destination's chain type and enforced at the transmitter, which still holds the
    ///      ERC-7930 envelope. This contract sees only a chainKey, which is a hash and cannot
    ///      be asked what chain type it came from.
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
            attributes
        );
    }

    /// @notice What `bootstrap` would cost, before anything is spent.
    ///
    /// @dev THE MESSAGE A CALLER IS LEAST ABLE TO GUESS THE PRICE OF, AND THE ONE THAT FAILS
    ///      MOST EXPENSIVELY: a bootstrap carries account creation as well as the payload,
    ///      and an underfunded one is not a retry, because the account still does not exist
    ///      on that chain.
    ///
    /// @dev IT APPLIES `_requireRoutable` SO THE BAR FAILS THE QUOTE WHEREVER IT FAILS THE
    ///      SEND, but NOT `bootstrap`'s caller check: a quote is taken by an interface or a
    ///      signer BEFORE that account exists, so the same check would make the function
    ///      uncallable in exactly the case it is for. There is nothing to protect on a `view`.
    function quoteBootstrap(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        _requireRoutable(destinationChainKey);
        return _quoteMessage(
            _recipientOn(destinationChainKey),
            Envelope.encodeBootstrap(owner, salt, calls),
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
        _requireRoutable(destinationChainKey);
        return _quoteMessage(
            _recipientOn(destinationChainKey),
            Envelope.encodeBootstrapElements(owner, salt, elements),
            attributes
        );
    }

    /// @notice The logic this side installs. Hub: a transmitter. Spoke: a receiver.
    function _accountImplementation() internal view virtual returns (address);

    /// @notice The initializer that logic is armed with, run by delegatecall inside the
    ///         upgrade so the account is never live and uninitialized.
    ///
    /// @dev THIS IS WHERE PROVIDER SETUP HAS TO HAPPEN, AND THERE IS NO SECOND CHANCE. The
    ///      proxy locks in the same call that arms it, and an account's own configuration (a
    ///      peer table, a delegate) is gated on its OWNER, which this contract is not. So a
    ///      transceiver has no authority over an account after creating it, and anything the
    ///      provider needs must be folded into this calldata. `virtual` all the way down for
    ///      exactly that reason.
    function _accountInitializer(address owner, bytes32 salt, Call[] memory calls)
        internal
        view
        virtual
        returns (bytes memory);

    /// @notice The base hook every concrete transceiver calls.
    /// @dev IT INITIALIZES NOTHING, AND THERE IS NOTHING TO INITIALIZE. OpenZeppelin stopped
    ///      transpiling `UUPSUpgradeable` in 5.6.0: it holds no state of its own, so
    ///      `__UUPSUpgradeable_init` was empty and is gone. The hook stays because it is what
    ///      a later base would hang its own setup on, and removing it would churn every
    ///      binding to delete one line.
    function __TransceiverBase_init() internal onlyInitializing {}

    /* ============================== authorization ============================== */

    /// @notice The authority for privileged operations on this transceiver.
    ///
    /// @dev DECLARED, NOT IMPLEMENTED. Inheriting an ownership system here would make this
    ///      base impossible to combine with a provider SDK that brings its own without the
    ///      concrete contract carrying two. Two owners on one contract is not a style
    ///      problem: it means a transceiver whose upgrades are "locked" behind one authority
    ///      can still be reconfigured through the other. So the base states the REQUIREMENT
    ///      and the concrete contract satisfies it from whatever it already has: `_checkOwner`
    ///      for `Ownable`, a role check for `AccessControl`, a raw msig comparison.
    function _checkAdmin() internal view virtual;

    modifier onlyAdmin() {
        _checkAdmin();
        _;
    }

    /* ================================= routing ================================= */

    /// @notice THE SEAM BETWEEN HUB AND SPOKE, one half: where the counterpart lives.
    ///
    /// @dev A hub answers out of the registry, applying a provenance bar to the counterpart's
    ///      claimed location; a spoke answers from a write-once value and rejects every key
    ///      but its home's. Protocol code above calls the same function either way.
    ///
    ///      The counterpart is NOT assumed to be at this contract's own address. That holds
    ///      on most EVM chains and not on zkSync or Tron, whose CREATE2 formulas differ, and
    ///      obviously not on Solana or the Move chains. So it is raw bytes in that chain's
    ///      own format: a 32-byte key cannot be turned back into a Solana pubkey.
    function _counterpartOn(bytes32 chainKey) internal view virtual returns (bytes memory);

    /// @notice THE SEAM, other half: how the chain itself is named.
    ///
    /// @dev SEPARATE FROM `_counterpartOn` ON PURPOSE. The two are configured independently
    ///      and can be missing independently, and folding them into one lookup would make a
    ///      half-wired destination un-inspectable: you could not read the part that IS
    ///      configured to find out which part is not.
    /// @dev The default answers from this contract's own write-once table. A spoke overrides
    ///      it, because its one destination is fixed at initialization.
    function _routeTo(bytes32 chainKey) internal view virtual returns (bytes memory) {
        return routeFor(chainKey);
    }

    /// @notice Revert unless this transceiver can reach `chainKey`: a counterpart it trusts
    ///         at its provenance bar, and a route to address it by.
    ///
    /// @dev IT IS CALLED FOR THE REVERT, AND THE NAME SAYS SO. Both lookups throw away their
    ///      values; what matters is that `_counterpartOn` refuses a counterpart below
    ///      `minCounterpartProvenance` and `_routeTo` refuses an unconfigured destination. A
    ///      function returning values nobody reads invites someone to remove the "unused"
    ///      call and take the check with it.
    function _requireRoutable(bytes32 chainKey) internal view {
        _counterpartOn(chainKey);
        _routeTo(chainKey);
    }

    /// @notice The counterpart on `chainKey`, as a binary interoperable address.
    ///
    /// @dev IT IS THE TWO HALVES OF `_requireRoutable`, JOINED. The route holds the chain and
    ///      `_counterpartOn` holds the address, which is exactly the pair ERC-7930 encodes
    ///      and exactly what an ERC-7786 gateway takes as a recipient. Building it here means
    ///      both lookups happen on the send path, so the provenance bar and the route
    ///      requirement are enforced by construction rather than by a separate call somebody
    ///      could drop.
    function _recipientOn(bytes32 chainKey) internal view returns (bytes memory) {
        Erc7930.Interop memory io = Erc7930.parseStrict(_routeTo(chainKey));
        return Erc7930.encode(io.chainType, io.chainRef, _counterpartOn(chainKey));
    }

    /// @notice Where this transceiver's counterpart lives on `chainKey`.
    function counterpartOn(bytes32 chainKey) public view returns (bytes memory) {
        return _counterpartOn(chainKey);
    }

    /// @notice The chain identifier `chainKey` is configured under.
    function routeTo(bytes32 chainKey) public view returns (bytes memory) {
        return _routeTo(chainKey);
    }

    /* ============================== upgrade lock =============================== */

    /// @notice Permanently disable upgrades. IRREVERSIBLE.
    /// @dev The proxy has to be upgradeable to get off the factory implementation it is
    ///      created with. Once the real transceiver is in place that capability is pure
    ///      downside: a transceiver decides which cross-chain payloads are authentic, so a
    ///      live upgrade key is a standing ability to forge one. Locking converts "we promise
    ///      not to" into "we cannot".
    function lockUpgrades() external onlyAdmin {
        upgradesLocked = true;
        emit UpgradesLocked();
    }

    /// @dev Gate for UUPS. Admin-only, and refused outright once locked.
    function _authorizeUpgrade(address) internal override onlyAdmin {
        if (upgradesLocked) revert UpgradesAreLocked();
    }

    /* ================================= inbound ================================= */

    /// @notice The one funnel every protocol binding routes an arriving message into.
    ///
    /// @dev AUTHENTICATION IS NOT THE BINDING'S JOB. It runs here, before anything is
    ///      decoded, so a new binding cannot ship without it: the binding's only inbound
    ///      responsibility is translating its SDK's callback into these three arguments.
    ///
    /// @dev IT SPLITS INTO TWO VIRTUALS BECAUSE TWO THINGS VARY INDEPENDENTLY. Who may send
    ///      varies by CARDINALITY: a spoke compares against constants, a hub resolves N
    ///      origins through the registry. What they may say varies by DIRECTION: a spoke
    ///      receives bootstraps, a hub receives reports. One overridable hook would let a
    ///      subclass get the second right and the first wrong.
    ///
    /// @param route   How the source chain is named, as the provider reported it.
    /// @param sender  The counterpart's address on that chain, in that chain's own format.
    /// @param message The body: see `Envelope`.
    function _onInbound(bytes memory route, bytes memory sender, bytes calldata message)
        internal
    {
        bytes32 chainKey = _authenticateOrigin(route, sender);
        _handleInbound(chainKey, message);
    }

    /// @notice Establish which chain this came from, and refuse it if the sender is not that
    ///         chain's counterpart.
    /// @dev Hub: reverse-index the route, then compare against the registry's counterpart at
    ///      the provenance bar. Spoke: compare against two write-once values.
    function _authenticateOrigin(bytes memory route, bytes memory sender)
        internal
        view
        virtual
        returns (bytes32 chainKey);

    /// @notice Act on an authenticated message.
    /// @dev Hub: a receiver report. Spoke: a bootstrap. Each side decodes exactly one shape,
    ///      which is why `Envelope` carries no type tag.
    function _handleInbound(bytes32 chainKey, bytes calldata message) internal virtual;
}
