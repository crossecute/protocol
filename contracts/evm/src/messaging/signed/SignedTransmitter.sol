// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICrossecuteGuard} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {GuardDiscovery} from "@crossecute/safe-guard/GuardDiscovery.sol";
import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {IConduitTransceiver, TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ISignedOwnerCalls} from "src/messaging/signed/ISignedOwnerCalls.sol";
import {SignedTransmitterLogic} from "src/messaging/signed/SignedTransmitterLogic.sol";
import {
    ExecutionLeaf,
    SignedDelivery,
    ISignedTransmitter,
    ISignedTransmitterInit
} from "src/messaging/signed/ISignedDispatch.sol";

/// @title SignedTransmitter
/// @notice A transmitter that can be created in signed mode (#108): every owner send and
///         bootstrap carries the owner Safe's signed transaction, and anyone can relay a leaf of
///         a root the Safe registered.
///
/// @dev Plain until `initializeSigned`, which the transceiver calls in `createTransmitter` when
///      the owner's guard advertises `ICrossecuteGuard`. In signed mode the owner Safe is the
///      creation-time owner (`deployer`), and ownership cannot move: the receivers hold that
///      Safe's authority.
///
/// @dev Source checks use the Safes' live authority; receivers verify against the creation
///      authority they store. A send that passes here can still fail there after an owner change,
///      without consuming receiver state (#109 delivers the change).
///
/// @dev State is ERC-7201 namespaced so it does not extend the base's sequential layout (R8.2).
abstract contract SignedTransmitter is OwnableTransmitter, ISignedTransmitter, ISignedTransmitterInit {
    /// @custom:storage-location erc7201:crossecute.storage.SignedTransmitter
    struct SignedTransmitterStorage {
        // `abi.encode(SafeRecord[])` at creation; its keccak256 is the graph in the conduit salt.
        bytes records;
        // Nonzero exactly in signed mode.
        bytes32 graph;
        mapping(bytes32 root => bool) roots;
        mapping(bytes32 leafHash => bool) relayed;
        mapping(bytes32 chainKey => bytes32 bodyHash) pendingBootstrap;
        bool relaying;
    }

    // keccak256(abi.encode(uint256(keccak256("crossecute.storage.SignedTransmitter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SIGNED_TRANSMITTER_STORAGE =
        0x8566b709a423746963d200f6840e900d54ab8ebbe69c13e71ed1cbb86e81aa00;

    event SignedModeSet(bytes32 graph);
    event RootRegistered(bytes32 indexed root);
    event LeafRelayed(bytes32 indexed leafHash, address indexed relayer);
    /// @dev `body` is what `retryBootstrap` takes, kept until a send of it succeeds.
    event BootstrapPending(bytes32 indexed destinationChainKey, bytes body);

    error NotSigned();
    error AlreadySigned();
    error OwnershipFixed();
    error SignedQuoteRequired();
    error RootNotPublished(bytes32 root);
    error RootNotRegistered(bytes32 root);
    error LeafAlreadyRelayed(bytes32 leafHash);
    error InsufficientPayment(uint256 fee, uint256 paid);
    error RefundFailed();
    error BalanceChanged(uint256 before, uint256 afterwards);
    error RelayReentered();
    error NoPendingBootstrap(bytes32 destinationChainKey);

    function _signedStorage() private pure returns (SignedTransmitterStorage storage $) {
        assembly ("memory-safe") {
            $.slot := SIGNED_TRANSMITTER_STORAGE
        }
    }

    function _graph() private view returns (bytes32 graph) {
        graph = _signedStorage().graph;
        if (graph == bytes32(0)) revert NotSigned();
    }

    /// @inheritdoc ISignedTransmitterInit
    function initializeSigned(bytes calldata records) external {
        if (msg.sender != transceiver) revert NotTransceiver(msg.sender);
        SignedTransmitterStorage storage $ = _signedStorage();
        if ($.graph != bytes32(0)) revert AlreadySigned();
        $.records = records;
        $.graph = keccak256(records);
        emit SignedModeSet($.graph);
    }

    /* ================================ owner calls =============================== */

    /// @notice In signed mode, send the owner Safe's signed `sendMessage` with its signatures and
    ///         nested approvals; the receiver checks them and runs the plain `payload`.
    /// @dev Paid from this balance, as in plain mode; `quoteSignedMessage` prices it.
    function sendMessage(bytes calldata recipient, bytes calldata payload, bytes[] calldata attributes)
        public
        payable
        override
        returns (bytes32 sendId)
    {
        if (_signedStorage().graph == bytes32(0)) return super.sendMessage(recipient, payload, attributes);
        _checkOwner();
        (bytes memory to, bytes memory wire, bytes[] memory options) = SignedTransmitterLogic.consumeMessage(msg.data);
        return _sendStandalone(to, wire, options);
    }

    function _sendStandalone(bytes memory recipient, bytes memory wire, bytes[] memory attributes)
        private
        returns (bytes32)
    {
        uint256 fee = _quoteStandalone(recipient, wire, attributes);
        _requireFunded(fee);
        emit MessageSent(bytes32(0), Erc7930.encodeEvm(block.chainid, address(this)), recipient, wire, fee, attributes);
        return _sendMessage(recipient, wire, attributes, fee);
    }

    function _quoteStandalone(bytes memory recipient, bytes memory wire, bytes[] memory attributes)
        private
        view
        returns (uint256)
    {
        _requireOwnRecipient(recipient);
        return _quoteMessage(recipient, wire, attributes);
    }

    /// @notice In signed mode, send the owner Safe's signed `bootstrap` through the transceiver.
    /// @dev The bundle is recorded before the send, which runs as `retryBootstrap`: if it reverts
    ///      the Safe transaction still succeeds, and anyone can retry with the logged body. A new
    ///      signed bootstrap replaces a pending one until a send succeeds.
    function bootstrap(bytes calldata payload, bytes[] calldata attributes)
        public
        payable
        override(TransmitterBase, ISignedOwnerCalls)
    {
        if (_signedStorage().graph == bytes32(0)) return super.bootstrap(payload, attributes);
        _checkOwner();
        (bytes memory body, bytes32 chainKey,,) = SignedTransmitterLogic.consumeBootstrap(msg.data);
        _signedStorage().pendingBootstrap[chainKey] = keccak256(body);
        emit BootstrapPending(chainKey, body);
        // A failed send leaves the bundle pending, which is the point of the try.
        try this.retryBootstrap(body) {} catch {}
    }

    /// @inheritdoc ISignedOwnerCalls
    /// @dev The guard lets the call through only for a root it published, which this checks too,
    ///      on the guard installed now.
    function registerRoot(bytes32 root) external onlyConduitOwner {
        _graph();
        if (!ICrossecuteGuard(GuardDiscovery.transactionGuard(deployer)).isPublished(root)) {
            revert RootNotPublished(root);
        }
        SignedTransmitterStorage storage $ = _signedStorage();
        if ($.roots[root]) revert RootAlreadyRegistered(root);
        $.roots[root] = true;
        emit RootRegistered(root);
    }

    /// @notice Ownership is fixed in signed mode.
    function transferOwnership(address newOwner) public virtual override {
        if (_signedStorage().graph != bytes32(0)) revert OwnershipFixed();
        super.transferOwnership(newOwner);
    }

    /* ============================== permissionless ============================== */

    /// @notice Retry a pending signed bootstrap with its logged body. Anyone may call; value tops
    ///         up the balance the fee is paid from.
    function retryBootstrap(bytes calldata body) external payable {
        bytes32 graph = _graph();
        (bytes32 chainKey, bytes memory route, bytes[] memory attributes) = SignedTransmitterLogic.bootstrapTarget(body);
        SignedTransmitterStorage storage $ = _signedStorage();
        if ($.pendingBootstrap[chainKey] != keccak256(body)) revert NoPendingBootstrap(chainKey);
        delete $.pendingBootstrap[chainKey];

        _markBootstrapped(chainKey, route, graph);
        IConduitTransceiver t = IConduitTransceiver(transceiver);
        uint256 fee = t.quoteBootstrapSigned(chainKey, deployer, conduitSalt, body, attributes);
        _requireFunded(fee);
        // forge-lint: disable-next-line(arbitrary-send-eth) the write-once transceiver
        t.bootstrapSigned{value: fee}(chainKey, deployer, conduitSalt, body, attributes);
    }

    /// @inheritdoc ISignedTransmitter
    /// @dev The caller pays the full fee. Excess and any synchronous provider refund go back to
    ///      the caller, and this conduit's balance ends where it began.
    function relayLeaf(SignedDelivery calldata registration, ExecutionLeaf calldata leaf, bytes32[] calldata proof)
        external
        payable
        returns (bytes32 sendId)
    {
        (registration, leaf, proof);
        SignedTransmitterStorage storage $ = _signedStorage();
        if ($.relaying) revert RelayReentered();
        $.relaying = true;
        uint256 balanceBefore = address(this).balance - msg.value;

        (bytes32 leafHash, bytes memory destination, bytes[] memory attributes, bytes memory wire, uint256 fee) =
            _relay();
        if (msg.value < fee) revert InsufficientPayment(fee, msg.value);
        $.relayed[leafHash] = true;
        emit LeafRelayed(leafHash, msg.sender);
        emit MessageSent(
            bytes32(0), Erc7930.encodeEvm(block.chainid, address(this)), destination, wire, fee, attributes
        );
        sendId = _sendMessage(destination, wire, attributes, fee);

        uint256 balance = address(this).balance;
        if (balance < balanceBefore) revert BalanceChanged(balanceBefore, balance);
        if (balance > balanceBefore) {
            // forge-lint: disable-next-line(reentrancy-balance) the relay lock is held and the balance is checked again after
            (bool ok,) = msg.sender.call{value: balance - balanceBefore}("");
            if (!ok) revert RefundFailed();
        }
        // forge-lint: disable-next-line(incorrect-strict-equality) the relay must leave this balance exactly as it found it
        if (address(this).balance != balanceBefore) revert BalanceChanged(balanceBefore, address(this).balance);
        $.relaying = false;
    }

    /* =================================== quotes ================================= */

    /// @notice Signed mode prices a send with its signatures, through `quoteSignedMessage`.
    function quoteMessage(bytes calldata recipient, bytes calldata payload, bytes[] calldata attributes)
        public
        view
        override
        returns (uint256)
    {
        if (_signedStorage().graph != bytes32(0)) revert SignedQuoteRequired();
        return super.quoteMessage(recipient, payload, attributes);
    }

    /// @notice Signed mode prices a bootstrap with its signatures, through `quoteSignedBootstrap`.
    function quoteBootstrap(bytes calldata payload, bytes[] calldata attributes)
        public
        view
        override
        returns (uint256)
    {
        if (_signedStorage().graph != bytes32(0)) revert SignedQuoteRequired();
        return super.quoteBootstrap(payload, attributes);
    }

    /// @notice What `sendMessage` would pay for `delivery`, a signed `sendMessage` to this
    ///         conduit. Nested approvals are read from the guards, as the send reads them.
    function quoteSignedMessage(SignedDelivery calldata delivery) external view returns (uint256) {
        _graph();
        delivery;
        (bytes memory recipient, bytes memory wire, bytes[] memory attributes) =
            SignedTransmitterLogic.quoteMessage(msg.data[4:]);
        return _quoteStandalone(recipient, wire, attributes);
    }

    /// @notice What `bootstrap` would pay for `delivery`, and the body it would log.
    function quoteSignedBootstrap(SignedDelivery calldata delivery)
        external
        view
        returns (uint256 fee, bytes memory body)
    {
        _graph();
        delivery;
        bytes32 chainKey;
        bytes[] memory attributes;
        (body, chainKey,, attributes) = SignedTransmitterLogic.quoteBootstrap(msg.data[4:]);
        fee = IConduitTransceiver(transceiver).quoteBootstrapSigned(chainKey, deployer, conduitSalt, body, attributes);
    }

    /// @notice What `relayLeaf` would charge for the same arguments.
    function quoteRelay(SignedDelivery calldata registration, ExecutionLeaf calldata leaf, bytes32[] calldata proof)
        external
        view
        returns (uint256 fee)
    {
        (registration, leaf, proof);
        (,,,, fee) = _relay();
    }

    /* ================================= builders ================================= */

    /// @dev `relayLeaf`'s checks on this conduit's own state, around the logic's checks of the
    ///      registration and leaf, read from this call's arguments.
    function _relay()
        private
        view
        returns (bytes32 leafHash, bytes memory destination, bytes[] memory attributes, bytes memory wire, uint256 fee)
    {
        _graph();
        bytes32 root;
        (root, leafHash, destination, attributes, wire) = SignedTransmitterLogic.relay(msg.data[4:]);
        SignedTransmitterStorage storage $ = _signedStorage();
        if (!$.roots[root]) revert RootNotRegistered(root);
        if ($.relayed[leafHash]) revert LeafAlreadyRelayed(leafHash);
        _requireOwnRecipient(destination);
        fee = _quoteMessage(destination, wire, attributes);
    }

    /* =================================== views ================================== */

    /// @notice The graph hash this conduit's salt commits to; zero for a plain conduit.
    function authorityGraph() external view returns (bytes32) {
        return _signedStorage().graph;
    }

    /// @notice The creation records forwarded at bootstrap, `abi.encode(SafeRecord[])`.
    function creationRecords() external view returns (bytes memory) {
        return _signedStorage().records;
    }

    function isRootRegistered(bytes32 root) external view returns (bool) {
        return _signedStorage().roots[root];
    }

    function isLeafRelayed(bytes32 leafHash) external view returns (bool) {
        return _signedStorage().relayed[leafHash];
    }

    /// @notice The hash of the body a retry to `destinationChainKey` must supply, or zero.
    function pendingBootstrap(bytes32 destinationChainKey) external view returns (bytes32) {
        return _signedStorage().pendingBootstrap[destinationChainKey];
    }
}
