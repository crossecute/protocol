// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    TransceiverCore,
    TransceiverConfig,
    ITransmitterInit,
    IAccountReceiverReport
} from "src/messaging/transceiver/TransceiverCore.sol";
import {IBootstrapAllowlist} from "src/messaging/transceiver/IBootstrapAllowlist.sol";
import {TransceiverExtension} from "src/messaging/transceiver/TransceiverExtension.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {ICrossProxy} from "src/account/CrossProxy.sol";
import {CrossProxyInitCode} from "src/account/CrossProxyInitCode.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

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
/// @dev Owned by the governor's account on this chain, derived at initialization
///      rather than typed, and configured by payloads the governor sends from its home. The owner
///      configures and can move no money. `GATEWAY_ROLE` is fixed at initialization with no
///      revoke path, since a transceiver's transports serve every account on its chain; a
///      compromised transport means a new transceiver.
///
/// @dev Holds what a bootstrap, a delivery, and an account's send reach. Initialization, owner
///      configuration, and views no contract calls live in `extension`, reached through
///      `fallback`, which keeps every binding under EIP-170 (#70). The extension is an
///      implementation immutable, so it changes only with a new transceiver, as this code does.
abstract contract TransceiverBase is TransceiverCore {
    /// @notice The `TransceiverExtension` every selector not declared here runs in.
    address public immutable extension;

    /// The contract `_deployAccount` reads `CrossProxy`'s initcode from (`CrossProxyInitCode`),
    /// written by this implementation's constructor. Zero on zkSync, which deploys by hash.
    address internal immutable _crossProxyInitCode;

    error NoExtension();
    /// @dev The extension derives accounts, or names this chain, differently from this contract.
    error ExtensionMismatch();

    constructor(address extension_) {
        if (extension_.code.length == 0) revert NoExtension();
        extension = extension_;
        _crossProxyInitCode = _storeCrossProxyInitCode();
    }

    /// @notice Write `CrossProxy`'s initcode for `_deployAccount` to read.
    /// @dev A variant whose `_deployAccount` does not read it overrides this to store nothing.
    function _storeCrossProxyInitCode() internal virtual returns (address) {
        return CrossProxyInitCode.store();
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

    /// @notice For a transceiver that derives account addresses Ethereum's way.
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
    ///      contract derives: an extension of another chain type would arm accounts at
    ///      addresses this contract does not create.
    ///
    /// @dev A transceiver decides which payloads are authentic, so a live upgrade key would be
    ///      a standing ability to forge any message. There is none: a transceiver is a
    ///      `CrossProxy` that `CrossProxyDeployer` arms with this initializer and locks in one
    ///      call, and neither this contract nor its extension has an upgrade function. A bug
    ///      in either is fixed only by redeploying, which re-derives every account.
    function __TransceiverBase_init(TransceiverConfig memory c, bool addressesDiverge_) internal onlyInitializing {
        if (TransceiverCore(extension).localChainKey() != localChainKey) revert ExtensionMismatch();
        TransceiverExtension(address(this)).initializeBase(c, addressesDiverge_);
        if (owner() != _predictCrossAccount(c.governorOwner, c.governorSalt, keccak256(c.governorHome))) {
            revert ExtensionMismatch();
        }
    }

    /* ============================== account manufacture ============================ */

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
        if (_addressesDiverge) {
            initCodeHash = _chainRegistry.providerDeployment(_messageProvider).crossProxyInitCodeHash;
            if (initCodeHash == bytes32(0)) revert NoProviderDeployment();
        }
        return abi.encodePacked(
            Create2.computeAddress(_accountSalt(owner, salt, localChainKey), initCodeHash, _evmCounterpartOn(chainKey))
        );
    }

    /// @notice Create the caller's transmitter.
    /// @dev The owner is `msg.sender`, never an argument, so no one can claim the address
    ///      another party will occupy on every chain.
    /// @param salt Chosen by the caller; `bytes32(0)` suits an owner who wants one account.
    /// @return account The transmitter, at the address its receivers occupy on parity chains.
    function createTransmitter(bytes32 salt) external returns (address account) {
        account = _createCrossAccount(msg.sender, salt, localChainKey, address(0), new Call[](0));
    }

    /// @notice Deploy the proxy at `salt`, and return where it actually landed.
    /// @dev Separate from the prediction because zkSync diverges in both: a different formula,
    ///      and deployment through a system contract against a pre-published bytecode hash, so
    ///      a variant there emits `new CrossProxy{salt: s}()`. Tron diverges only in the formula.
    function _deployAccount(bytes32 salt) internal virtual returns (address deployed) {
        return Create2.deploy(0, salt, CrossProxyInitCode.load(_crossProxyInitCode));
    }

    /// @notice Deploy an owner's account and arm it: a transmitter if it is homed here, a
    ///         receiver otherwise, through the same argument-free proxy.
    ///
    /// @dev Deploy, arm, and lock happen in one call, so no account ever has logic and a live
    ///      upgrade key at once.
    ///
    /// @dev Asserts the deployment landed where `_predictCrossAccount` said. Every address the
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

        account = _predictCrossAccount(owner, salt, homeChainKey);
        if (account.code.length != 0) revert CrossAccountExists(owner, salt, account);

        address deployed = _deployAccount(_accountSalt(owner, salt, homeChainKey));
        if (deployed != account) revert AccountAddressMismatch(account, deployed);

        ICrossProxy(account)
            .upgradeInitializeAndLock(
                implementation, _accountInitializer(owner, salt, homeChainKey, sourceTransmitter, calls)
            );

        emit CrossAccountCreated(owner, account, salt, homeChainKey);
    }

    /// @notice The logic an account homed on `homeChainKey` is armed with.
    function _accountImplementation(bytes32 homeChainKey) internal view virtual returns (address) {
        return homeChainKey == localChainKey ? _transmitterImplementation : _receiverImplementation;
    }

    /// @notice The initializer that logic is armed with, run by delegatecall inside the
    ///         upgrade so the account is never live and uninitialized.
    /// @dev The proxy locks in the same call, and an account's own configuration is gated on
    ///      its owner, not this contract, so all provider setup must be in this calldata. A
    ///      transmitter takes its salt, since an account cannot recover it from its own
    ///      address; a receiver answers to the transmitter its bootstrap carried, on its home,
    ///      named here by chainKey as an ERC-7786 gateway reports it.
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
        return abi.encodeCall(IReceiverInit.initialize, (sourceTransmitter, homeChainKey, calls));
    }

    /* =================================== bootstrap ================================= */

    /// @notice Stand an account up on a chain that has none, and carry its payload.
    ///
    /// @dev Callable only by the account `(owner, salt)` resolves to when homed on this chain,
    ///      which is what lets the owner and salt travel in the message without a caller
    ///      claiming another identity. An account homed elsewhere bootstraps from its own home.
    ///
    /// @dev `_minCounterpartProvenance` applies here through `_requireRoutable`, as it does to
    ///      every message this transceiver sends to or accepts from a chain (`_counterpartOn`).
    ///      An account's later sends leave from its transmitter, which does not read it.
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
            Envelope.encodeBootstrap(owner, salt, _transmitterWord(_allowedAccount(owner, salt)), calls),
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
            Envelope.encodeBootstrapElements(owner, salt, _transmitterWord(_allowedAccount(owner, salt)), elements),
            attributes
        );
    }

    /// @notice Refuse any caller but the account `(owner, salt)` resolves to here, and return
    ///         it as the bootstrap carries it.
    function _bootstrapCaller(address owner, bytes32 salt) private view returns (bytes32) {
        address account = _allowedAccount(owner, salt);
        if (account != msg.sender) revert NotTheAccount(owner, salt, msg.sender);
        return _transmitterWord(account);
    }

    /// @notice The account `(owner, salt)` resolves to here, refused unless the allowlist, where
    ///         one is set, allows it.
    /// @dev Shared by `bootstrap` and its quotes so they refuse the same accounts.
    function _allowedAccount(address owner, bytes32 salt) private view returns (address account) {
        account = _localAccount(owner, salt);
        IBootstrapAllowlist allowlist = _bootstrapAllowlist;
        if (address(allowlist) != address(0) && !allowlist.isAllowed(account)) revert NotAllowed(account);
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
    ///      Otherwise, if the home is `Predetermined`, the receiver must sit at its transmitter's
    ///      address; a home graded below that (zkSync, Tron) has its transmitter elsewhere.
    function _bootstrapInbound(
        address owner,
        bytes32 salt,
        bytes32 home,
        address sourceTransmitter,
        Call[] memory calls
    ) internal {
        address receiver = _createCrossAccount(owner, salt, home, sourceTransmitter, calls);
        if (_addressesDiverge) {
            _reportReceiver(home, owner, salt, receiver);
        } else if (receiver != sourceTransmitter && _chainRegistry.provenanceFor(home) == Provenance.Predetermined) {
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
        bytes memory payload = _reportPayload(owner, salt, receiver);

        _reporting = true;
        _sendMessage(recipient, payload, new bytes[](0), _quoteMessage(recipient, payload, new bytes[](0)));
        _reporting = false;
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
    ///      one derives cannot replace a `Predetermined` fact with a reported one.
    ///
    /// @dev The destination cannot choose the account: `chainKey` is authenticated and the
    ///      account is `_localAccount` of the stated pair, the derivation `bootstrap` checked the
    ///      caller against. The account refuses a second report.
    ///
    /// @dev The reported address must be on the reporting chain. An authenticated transceiver
    ///      can still report a wrong address on its own chain; the account keeps the first
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
        if (address(_chainRegistry) == address(0)) return false;
        return _chainRegistry.requiresReceiverCallback(chainKey);
    }
}
