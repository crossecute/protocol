// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    TransceiverCore,
    TransceiverConfig,
    ITransmitterInit,
    IConduitReceiverReport
} from "src/messaging/transceiver/TransceiverCore.sol";
import {IBootstrapAllowlist} from "src/messaging/transceiver/IBootstrapAllowlist.sol";
import {TransceiverExtension} from "src/messaging/transceiver/TransceiverExtension.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";
import {ISignedReceiverInit} from "src/messaging/inbound/ISignedReceiver.sol";
import {ISignedTransmitterInit} from "src/messaging/outbound/ISignedTransmitter.sol";
import {Call} from "src/messaging/Call.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {Conduits} from "src/conduit/Conduits.sol";
import {ProxyInitCode} from "src/conduit/ProxyInitCode.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title TransceiverBase
/// @notice One transceiver per chain per provider. It creates transmitters for conduits homed
///         here and receivers for conduits homed on any configured origin, and it sends and
///         accepts both bootstraps and receiver reports.
///
/// @dev A conduit's CREATE2 salt is `(owner, salt, homeChainKey)` and nothing else, so one
///      transmitter has one receiver per destination, at an address fixed before the first
///      message, and the transmitter a conduit has here never collides with the receiver a
///      conduit homed elsewhere has here. A receiver is made only by an authenticated bootstrap.
///
/// @dev Runs no payload of its own: an inbound message is an `Envelope`, acted on in
///      `_handleInbound`, and a bootstrap creates the conduit and runs its payload in the same
///      delivery. A first payload that should wait carries a call to the new receiver's own
///      `commit`. No approvals are held here, so no origin can approve or cancel on another's
///      behalf.
///
/// @dev Owned by the governor's conduit on this chain, derived at initialization
///      rather than typed, and configured by payloads the governor sends from its home. The owner
///      configures and can move no money. `GATEWAY_ROLE` is fixed at initialization with no
///      revoke path, since a transceiver's transports serve every conduit on its chain; a
///      compromised transport means a new transceiver.
///
/// @dev Holds what a bootstrap, a delivery, and a conduit's send reach. Initialization, owner
///      configuration, and views no contract calls live in `extension`, reached through
///      `fallback`, which keeps every binding under EIP-170 (#70). The extension is an
///      implementation immutable, so it changes only with a new transceiver, as this code does.
abstract contract TransceiverBase is TransceiverCore {
    /// @notice The `TransceiverExtension` every selector not declared here runs in.
    address public immutable extension;

    /// The contract `_deployConduit` reads `Proxy`'s initcode from (`ProxyInitCode`),
    /// written by this implementation's constructor. Zero on zkSync, which deploys by hash.
    address internal immutable _proxyInitCode;

    error NoExtension();
    /// @dev The extension derives conduits, or names this chain, differently from this contract.
    error ExtensionMismatch();

    constructor(address extension_) {
        if (extension_.code.length == 0) revert NoExtension();
        extension = extension_;
        _proxyInitCode = _storeProxyInitCode();
    }

    /// @notice Write `Proxy`'s initcode for `_deployConduit` to read.
    /// @dev A variant whose `_deployConduit` does not read it overrides this to store nothing.
    function _storeProxyInitCode() internal virtual returns (address) {
        return ProxyInitCode.store();
    }

    /// @notice Run any other selector in the extension, against this contract's storage.
    fallback() external payable {
        address target = extension;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }

    /// @notice Accept the float reports are paid from.
    receive() external payable {}

    /* ================================ initialization ============================== */

    /// @notice For a transceiver that derives conduit addresses Ethereum's way.
    function __TransceiverBase_init(TransceiverConfig memory c) internal onlyInitializing {
        __TransceiverBase_init(c, false);
    }

    /// @notice Configure and grant the gateways, in the extension.
    ///
    /// @dev `addressesDiverge_` is the contract's own fact: `DivergentTransceiver` passes true,
    ///      having set its derivation inputs first, since the owner is derived with them.
    ///
    /// @dev A self-call, so the extension can refuse any caller but this contract
    ///      (`TransceiverExtension.initializeBase`). The owner it derived must be the one this
    ///      contract derives: an extension of another chain type would arm conduits at
    ///      addresses this contract does not create.
    ///
    /// @dev A transceiver decides which payloads are authentic, so a live upgrade key would be
    ///      a standing ability to forge any message. There is none: a transceiver is a
    ///      `Proxy` that `ProxyDeployer` arms with this initializer and locks in one
    ///      call, and neither this contract nor its extension has an upgrade function. A bug
    ///      in either is fixed only by redeploying, which re-derives every conduit.
    function __TransceiverBase_init(TransceiverConfig memory c, bool addressesDiverge_) internal onlyInitializing {
        if (TransceiverCore(extension).localChainKey() != localChainKey) revert ExtensionMismatch();
        TransceiverExtension(address(this)).initializeBase(c, addressesDiverge_);
        if (owner() != _predictConduit(c.governorOwner, c.governorSalt, keccak256(c.governorHome))) {
            revert ExtensionMismatch();
        }
    }

    /* ============================== conduit manufacture ============================ */

    /// @notice Where `(owner, salt)`'s receiver will sit on `chainKey`, for a conduit homed on
    ///         this chain, where `chainKey` derives addresses with Ethereum's CREATE2.
    /// @dev Ethereum's CREATE2 over this provider's transceiver there, which is the counterpart
    ///      on that chain. It equals the conduit's own address only when this chain also uses
    ///      that formula and the same deployer deployed both transceivers, which is why a
    ///      transmitter records this rather than `address(this)`.
    ///
    /// @dev The initcode hash is the destination's, not this compiler's: on zkSync and Tron
    ///      `PROXY_INIT_CODE_HASH` is the local compiler's and not what an EVM destination
    ///      deploys (#30), so a diverging transceiver takes it from the provider's deployment
    ///      record, which R8.4 holds equal to solc's.
    function predictReceiver(bytes32 chainKey, address owner, bytes32 salt) public view returns (bytes memory) {
        return predictReceiver(chainKey, owner, salt, bytes32(0));
    }

    /// @notice `predictReceiver`, for a signed conduit whose salt commits to `graph`.
    function predictReceiver(bytes32 chainKey, address owner, bytes32 salt, bytes32 graph)
        public
        view
        returns (bytes memory)
    {
        return abi.encodePacked(_conduitUnder(_evmCounterpartOn(chainKey), owner, salt, localChainKey, graph));
    }

    /// @dev Where `(owner, salt)`'s conduit homed on `homeChainKey` sits under the transceiver at
    ///      `transceiver_`, with the initcode hash that chain's compiler produces.
    function _conduitUnder(address transceiver_, address owner, bytes32 salt, bytes32 homeChainKey, bytes32 graph)
        private
        view
        returns (address)
    {
        bytes32 initCodeHash = PROXY_INIT_CODE_HASH;
        if (_addressesDiverge) {
            initCodeHash = _chainRegistry.providerDeployment(_messageProvider).proxyInitCodeHash;
            if (initCodeHash == bytes32(0)) revert NoProviderDeployment();
        }
        return Create2.computeAddress(_conduitSalt(owner, salt, homeChainKey, graph), initCodeHash, transceiver_);
    }

    /// @notice Create the caller's transmitter.
    /// @dev The owner is `msg.sender`, never an argument, so no one can claim the address
    ///      another party will occupy on every chain.
    ///
    /// @dev Signed mode (#108) when the caller is a Safe whose transaction guard advertises
    ///      `ICrossecuteGuard`: the conduit's salt also commits to the caller's live owner graph,
    ///      and the transmitter keeps those records to forward at bootstrap. The mode is fixed
    ///      here; a guard installed or removed later changes neither the address nor the mode.
    /// @param salt Chosen by the caller; `bytes32(0)` suits an owner who wants one conduit.
    /// @return conduit The transmitter, at the address its receivers occupy on parity chains.
    function createTransmitter(bytes32 salt) external returns (address conduit) {
        bytes memory records = TransceiverExtension(address(this)).signedAuthority(msg.sender);
        if (records.length == 0) {
            return _createConduit(msg.sender, salt, localChainKey, bytes32(0), address(0), new Call[](0));
        }

        conduit = _createConduit(msg.sender, salt, localChainKey, keccak256(records), address(0), new Call[](0));
        ISignedTransmitterInit(conduit).initializeSigned(records);
    }

    /// @notice Deploy the proxy at `salt`, and return where it actually landed.
    /// @dev Separate from the prediction because zkSync diverges in both: a different formula,
    ///      and deployment through a system contract against a pre-published bytecode hash, so
    ///      a variant there emits `new Proxy{salt: s}()`. Tron diverges only in the formula.
    function _deployConduit(bytes32 salt) internal virtual returns (address deployed) {
        return Conduits.deploy(salt, _proxyInitCode);
    }

    /// @notice Deploy an owner's conduit and arm it: a transmitter if it is homed here, a
    ///         receiver otherwise, through the same argument-free proxy.
    ///
    /// @dev The checks around the deployment are `Conduits`', shared with every other
    ///      conduit creator. The prediction it holds the deployment to is the one every published
    ///      address comes from: a transmitter's recorded counterpart, a receiver's
    ///      `sourceTransmitter`, the conduit a report is forwarded to.
    /// @param sourceTransmitter The transmitter a receiver will answer to; zero for a
    ///        transmitter, which answers to its owner.
    /// @param graph Zero for a plain conduit. A signed conduit is armed with the plain
    ///        initializer and no calls, and its caller completes it with `initializeSigned` in
    ///        the same call, so provider setup has one path for both modes.
    function _createConduit(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        bytes32 graph,
        address sourceTransmitter,
        Call[] memory calls
    ) internal returns (address conduit) {
        if (owner == address(0)) revert ZeroOwner();

        address implementation = _conduitImplementation(homeChainKey);
        if (implementation == address(0)) revert NoConduitImplementation();

        conduit = _predictConduit(owner, salt, homeChainKey, graph);
        Conduits.requireVacant(conduit, owner, salt);

        address deployed = _deployConduit(_conduitSalt(owner, salt, homeChainKey, graph));
        Conduits.requireLanded(conduit, deployed);

        Conduits.arm(conduit, implementation, _conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls));

        emit ConduitCreated(owner, conduit, salt, homeChainKey);
        if (graph != bytes32(0)) emit SignedConduitCreated(conduit, graph);
    }

    /// @notice The logic a conduit homed on `homeChainKey` is armed with.
    function _conduitImplementation(bytes32 homeChainKey) internal view virtual returns (address) {
        return homeChainKey == localChainKey ? _transmitterImplementation : _receiverImplementation;
    }

    /// @notice The initializer that logic is armed with, run by delegatecall inside the
    ///         upgrade so the conduit is never live and uninitialized.
    /// @dev The proxy locks in the same call, and a conduit's own configuration is gated on
    ///      its owner, not this contract, so all provider setup must be in this calldata. A
    ///      transmitter takes its salt, since a conduit cannot recover it from its own
    ///      address; a receiver answers to the transmitter its bootstrap carried, on its home,
    ///      named here by chainKey as an ERC-7786 gateway reports it.
    function _conduitInitializer(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls
    ) internal view virtual returns (bytes memory) {
        if (homeChainKey == localChainKey) {
            return abi.encodeCall(ITransmitterInit.initialize, (owner, address(this), salt));
        }
        return abi.encodeCall(IReceiverInit.initialize, (sourceTransmitter, homeChainKey, calls));
    }

    /* =================================== bootstrap ================================= */

    /// @notice Stand a conduit up on a chain that has none, and carry its payload.
    ///
    /// @dev Callable only by the conduit `(owner, salt)` resolves to when homed on this chain,
    ///      which is what lets the owner and salt travel in the message without a caller
    ///      claiming another identity. A conduit homed elsewhere bootstraps from its own home.
    ///
    /// @dev `_minCounterpartProvenance` applies here through `_requireRoutable`, as it does to
    ///      every message this transceiver sends to or accepts from a chain (`_counterpartOn`).
    ///      A conduit's later sends leave from its transmitter, which does not read it.
    function bootstrap(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external payable {
        bytes32 transmitter = _bootstrapCaller(owner, salt);
        _sendBootstrap(
            destinationChainKey, owner, salt, _bootstrapEnvelope(owner, salt, transmitter, calls), attributes
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

    /// @notice `bootstrap` for a signed conduit, carrying `abi.encode(SignedBootstrap)`, which
    ///         the destination's receiver verifies before it stores authority or runs a call.
    /// @dev The caller check derives with the graph of the records in `body`, so only the signed
    ///      conduit of `(owner, salt)` with exactly those records can send it.
    function bootstrapSigned(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        bytes calldata body,
        bytes[] calldata attributes
    ) external payable {
        bytes32 transmitter = _bootstrapCaller(owner, salt, _bootstrapGraph(body));
        _sendBootstrap(
            destinationChainKey, owner, salt, Envelope.encodeSignedBootstrap(owner, salt, transmitter, body), attributes
        );
    }

    /// @notice What `bootstrapSigned` would cost.
    function quoteBootstrapSigned(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        bytes calldata body,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        address conduit = _allowedConduit(owner, salt, _bootstrapGraph(body));
        return _quoteBootstrap(
            destinationChainKey,
            Envelope.encodeSignedBootstrap(owner, salt, _transmitterWord(conduit), body),
            attributes
        );
    }

    /// @dev Asked of the receiver logic, which decodes and validates the same body on arrival.
    function _bootstrapGraph(bytes memory body) private view returns (bytes32) {
        return ISignedReceiverInit(_receiverImplementation).bootstrapGraph(body);
    }

    /// @notice Empty: this transceiver sends a conduit's bootstrap itself, through `bootstrap`.
    function conduitBootstrap(bytes calldata, address, bytes32, bytes calldata)
        external
        pure
        returns (bytes memory recipient, bytes memory message)
    {
        return ("", "");
    }

    /// @notice What `bootstrap` would cost, before anything is spent.
    /// @dev Applies `_requireRoutable`, so it fails wherever the send would, but not
    ///      `bootstrap`'s caller check: a quote is taken before the conduit exists.
    function quoteBootstrap(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        return _quoteBootstrap(
            destinationChainKey,
            _bootstrapEnvelope(owner, salt, _transmitterWord(_allowedConduit(owner, salt)), calls),
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
            Envelope.encodeBootstrapElements(owner, salt, _transmitterWord(_allowedConduit(owner, salt)), elements),
            attributes
        );
    }

    /// @notice The envelope `bootstrap` sends and `quoteBootstrap` prices, built in one place so
    ///         the two cannot drift.
    function _bootstrapEnvelope(address owner, bytes32 salt, bytes32 transmitter, Call[] calldata calls)
        private
        pure
        returns (bytes memory)
    {
        return Envelope.encodeBootstrap(owner, salt, transmitter, calls);
    }

    /// @notice Refuse any caller but the conduit `(owner, salt)` resolves to here, and return
    ///         it as the bootstrap carries it.
    function _bootstrapCaller(address owner, bytes32 salt) private view returns (bytes32) {
        return _bootstrapCaller(owner, salt, bytes32(0));
    }

    function _bootstrapCaller(address owner, bytes32 salt, bytes32 graph) private view returns (bytes32) {
        address conduit = _allowedConduit(owner, salt, graph);
        if (conduit != msg.sender) revert NotTheConduit(owner, salt, msg.sender);
        return _transmitterWord(conduit);
    }

    /// @notice The conduit `(owner, salt)` resolves to here, refused unless the allowlist, where
    ///         one is set, allows it.
    /// @dev Shared by `bootstrap` and its quotes so they refuse the same conduits.
    function _allowedConduit(address owner, bytes32 salt) private view returns (address conduit) {
        return _allowedConduit(owner, salt, bytes32(0));
    }

    function _allowedConduit(address owner, bytes32 salt, bytes32 graph) private view returns (address conduit) {
        conduit = _localConduit(owner, salt, graph);
        IBootstrapAllowlist allowlist = _bootstrapAllowlist;
        if (address(allowlist) != address(0) && !allowlist.isAllowed(conduit)) revert NotAllowed(conduit);
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
        _requireBootstrappable(destinationChainKey);
        emit BootstrapSent(destinationChainKey, owner, salt);
        _sendMessage(_recipientOn(destinationChainKey), envelope, attributes, _bootstrapSendValue(destinationChainKey));
    }

    /// @dev The quote of `_sendBootstrap`, over the same envelope, plus the destination's fee.
    function _quoteBootstrap(bytes32 destinationChainKey, bytes memory envelope, bytes[] calldata attributes)
        private
        view
        returns (uint256)
    {
        _requireBootstrappable(destinationChainKey);
        return
            _quoteMessage(_recipientOn(destinationChainKey), envelope, attributes) + _bootstrapFee[destinationChainKey];
    }

    /// @notice Refuse a bootstrap that cannot be sent, or that would cost the destination's float
    ///         more than it paid.
    /// @dev A reporting destination pays the report from its float, so a free bootstrap there
    ///      would let anyone drain it. The fee's size is governance; zero is refused here.
    function _requireBootstrappable(bytes32 destinationChainKey) private view {
        _requireRoutable(destinationChainKey);
        if (!isLive(destinationChainKey)) revert DestinationNotLive(destinationChainKey);
        if (_bootstrapFee[destinationChainKey] == 0 && reportsReceiver(destinationChainKey)) {
            revert NoBootstrapFee(destinationChainKey);
        }
    }

    /// @notice An EVM transmitter as a bootstrap carries it: left-padded to a word.
    function _transmitterWord(address transmitter) private pure returns (bytes32) {
        return bytes32(uint256(uint160(transmitter)));
    }

    /// @notice Take the destination's fee off the top of `msg.value`, forward it, and return
    ///         what is left for the send.
    /// @dev Paid before the send, which reaches a provider endpoint and arbitrary code beyond
    ///      it; a later revert unwinds the payment too. `call` rather than `transfer`, so a
    ///      treasury contract is not held to the 2300-gas stipend.
    function _bootstrapSendValue(bytes32 chainKey) internal returns (uint256) {
        uint256 fee = _bootstrapFee[chainKey];
        if (msg.value < fee) revert InsufficientBootstrapFee(fee, msg.value);
        if (fee == 0) return msg.value;

        address to = _treasury;
        emit BootstrapFeePaid(chainKey, to, fee);

        // forge-lint: disable-next-line(arbitrary-send-eth) the write-once treasury
        (bool ok,) = to.call{value: fee}("");
        if (!ok) revert FeeTransferFailed(to, fee);
        return msg.value - fee;
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
    /// @dev A report is for a conduit homed here. A bootstrap creates a receiver homed on the
    ///      authenticated origin, never on a chain the message states. Each decoder checks the
    ///      `Envelope` kind, so a wrong shape is refused by name rather than misread.
    function _handleInbound(bytes32 origin, bytes calldata message) internal virtual {
        uint8 kind = Envelope.kindOf(message);
        if (kind == Envelope.RECEIVER_REPORT) {
            (address reportOwner, bytes32 reportSalt, bytes memory interop) = Envelope.decodeReceiverReport(message);
            _onDestinationReceiver(origin, reportOwner, reportSalt, interop);
            return;
        }

        if (kind == Envelope.SIGNED_BOOTSTRAP) {
            (address signedOwner, bytes32 signedSalt, bytes32 signedTransmitter, bytes memory body) =
                Envelope.decodeSignedBootstrap(message);
            _signedBootstrapInbound(signedOwner, signedSalt, origin, _evmTransmitter(signedTransmitter), body);
            return;
        }

        (address owner, bytes32 salt, bytes32 transmitter, Call[] memory calls) = Envelope.decodeBootstrap(message);
        _bootstrapInbound(owner, salt, origin, _evmTransmitter(transmitter), calls);
    }

    function _evmTransmitter(bytes32 transmitter) private pure returns (address) {
        if (uint256(transmitter) >> 160 != 0) revert SourceTransmitterNotEvm(transmitter);
        return address(uint160(uint256(transmitter)));
    }

    /// @notice Stand up the receiver of a conduit homed on `home`, and run its first payload.
    ///
    /// @dev Never deferred: the receiver is created and its payload run in the delivery that
    ///      carries them, reachable only from an authenticated `_onInbound`.
    ///
    /// @dev Where this chain diverges, the home cannot derive the receiver, so it is reported.
    ///      Otherwise, if the home is `Predetermined`, the carried transmitter must be the one the
    ///      home's transceiver, as the registry records it, derives for this conduit; a home graded
    ///      below that (zkSync, Tron) has its transmitter elsewhere. The receiver sits at the
    ///      transmitter's address only when both chains' transceivers share a deployer.
    function _bootstrapInbound(
        address owner,
        bytes32 salt,
        bytes32 home,
        address sourceTransmitter,
        Call[] memory calls
    ) internal {
        address receiver = _createConduit(owner, salt, home, bytes32(0), sourceTransmitter, calls);
        if (_addressesDiverge) {
            _reportReceiver(home, owner, salt, receiver);
        } else if (_chainRegistry.provenanceFor(home) == Provenance.Predetermined) {
            address expected = _conduitUnder(_evmCounterpartOn(home), owner, salt, home, bytes32(0));
            if (sourceTransmitter != expected) revert SourceTransmitterMismatch(expected, sourceTransmitter);
        }
    }

    /// @notice Stand up the signed receiver of a conduit homed on `home`, or acknowledge a
    ///         repeat of the bootstrap that already did.
    ///
    /// @dev The carried transmitter must be the one this chain derives for `(owner, salt)` and
    ///      the body's graph under the home's transceiver, so the home must be `Predetermined`:
    ///      the receiver accepts Safe transactions signed for that address and nothing else
    ///      vouches for it. The receiver derives with the same graph, so its address commits to
    ///      the authority it stores. A diverging chain would have to report the receiver with
    ///      the graph, which no report carries yet.
    ///
    /// @dev A second delivery reaches the receiver's own check instead of `ConduitExists`: the
    ///      same leaf inside its window returns, anything else reverts. It changes nothing either
    ///      way.
    function _signedBootstrapInbound(
        address owner,
        bytes32 salt,
        bytes32 home,
        address sourceTransmitter,
        bytes memory body
    ) internal {
        if (_addressesDiverge) revert SignedReceiverNotDerivable();
        if (_chainRegistry.provenanceFor(home) != Provenance.Predetermined) revert SourceTransmitterNotDerivable(home);
        bytes32 graph = _bootstrapGraph(body);
        address expected = _conduitUnder(_evmCounterpartOn(home), owner, salt, home, graph);
        if (sourceTransmitter != expected) revert SourceTransmitterMismatch(expected, sourceTransmitter);

        address receiver = _predictConduit(owner, salt, home, graph);
        if (receiver.code.length != 0) {
            ISignedReceiverInit(receiver).requireBootstrapRepeat(body);
            return;
        }
        _createConduit(owner, salt, home, graph, sourceTransmitter, new Call[](0));
        ISignedReceiverInit(receiver)
            .initializeSigned(Erc7930.evmChainId(Erc7930.parseStrict(routeFor(home))), owner, graph, body);
    }

    /* ================================== the report ================================= */

    /// @notice Tell the conduit's home where its receiver landed.
    /// @dev Paid from this contract's float, since it is nested in a delivery where
    ///      `msg.value` is zero. A failed send reverts the conduit creation with it, which
    ///      keeps the bootstrap retryable once the float is topped up.
    function _reportReceiver(bytes32 home, address owner, bytes32 salt, address receiver) internal {
        emit ReceiverReported(home, owner, salt, receiver);

        bytes memory recipient = _recipientOn(home);
        bytes memory payload = _reportPayload(owner, salt, receiver);

        _reporting = true;
        _sendMessage(recipient, payload, new bytes[](0), _quoteMessage(recipient, payload, new bytes[](0)));
        _reporting = false;
    }

    /// @notice A destination reports where it created the receiver of a conduit homed here.
    ///
    /// @dev For chains this one cannot derive: Starknet's Pedersen derivation, and zkSync's and
    ///      Tron's CREATE2 formulas. Internal, so reachable only from an authenticated
    ///      `_onInbound`.
    ///
    /// @dev Written to the conduit, not the registry, because the transmitter is what
    ///      addresses that receiver and the registry is out of the send path. The registry
    ///      still decides which chains may report (`requiresReceiverCallback`), so a chain this
    ///      one derives cannot replace a `Predetermined` fact with a reported one.
    ///
    /// @dev The destination cannot choose the conduit: `chainKey` is authenticated and the
    ///      conduit is `_localConduit` of the stated pair, the derivation `bootstrap` checked the
    ///      caller against. The conduit refuses a second report.
    ///
    /// @dev The reported address must be on the reporting chain. An authenticated transceiver
    ///      can still report a wrong address on its own chain; the conduit keeps the first
    ///      one, so a compromised transceiver costs only its own chain.
    /// @param interop Canonical ERC-7930 bytes for the receiver on the destination.
    function _onDestinationReceiver(bytes32 chainKey, address owner, bytes32 salt, bytes memory interop) internal {
        if (address(_chainRegistry) == address(0)) revert NoChainRegistry();
        if (owner == address(0)) revert ZeroOwner();
        if (!_chainRegistry.requiresReceiverCallback(chainKey)) {
            revert ChainDoesNotReport(chainKey);
        }

        bytes32 reported = Erc7930.chainKey(interop);
        if (reported != chainKey) revert ReportedChainMismatch(chainKey, reported);

        address conduit = _localConduit(owner, salt);
        IConduitReceiverReport(conduit).onDestinationReceiverReported(chainKey, Erc7930.parseStrict(interop).addr);
        emit DestinationReceiverReported(chainKey, owner, salt, conduit);
    }

    /// @notice Whether sends may reach this provider's transceiver on `chainKey`: the registry has
    ///         marked it live.
    /// @dev Asked by a transmitter, which holds no registry, before every send and quote. With no
    ///      registry it answers false.
    function isLive(bytes32 chainKey) public view returns (bool) {
        if (address(_chainRegistry) == address(0)) return false;
        return _chainRegistry.isLive(chainKey, _messageProvider);
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
        if (address(_chainRegistry) == address(0)) return false;
        return _chainRegistry.requiresReceiverCallback(chainKey);
    }
}
