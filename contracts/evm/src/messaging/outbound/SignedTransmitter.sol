// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICrossecuteGuard} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {GuardDiscovery} from "@crossecute/safe-guard/GuardDiscovery.sol";
import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {IConduitTransceiver, TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ISignedTransmitter, ISignedTransmitterInit} from "src/messaging/outbound/ISignedTransmitter.sol";
import {ExecutionLeaf, SafeTxEvidence} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {SignedTransmitterLib} from "src/messaging/outbound/SignedTransmitterLib.sol";

/// @title SignedTransmitter
/// @notice A transmitter that can be created in signed mode (#108): every owner send carries
///         the owner Safe's signed transaction, a bootstrap carries its live authority records,
///         and anyone can relay a leaf of a root the Safe registered.
///
/// @dev Plain until `initializeSigned`, which the transceiver calls in `createTransmitter` when
///      the owner's guard advertises `ICrossecuteGuard`. In signed mode the owner Safe is the
///      creation-time owner (`deployer`), and ownership cannot move: the receivers hold that
///      Safe's authority.
///
/// @dev Source checks use the Safes' live authority; each receiver verifies against the
///      authority its bootstrap delivered, read live when that bootstrap was sent. A send that
///      passes here can still fail there after a later owner change, without consuming receiver
///      state (#109 delivers the change).
///
/// @dev State is ERC-7201 namespaced so it does not extend the base's sequential layout (R8.2).
abstract contract SignedTransmitter is OwnableTransmitter, ISignedTransmitter, ISignedTransmitterInit {
    /// @custom:storage-location erc7201:crossecute.storage.SignedTransmitter
    struct SignedTransmitterStorage {
        bool signed;
        mapping(bytes32 root => bool) roots;
        mapping(bytes32 leafHash => bool) relayed;
        bool relaying;
    }

    // keccak256(abi.encode(uint256(keccak256("crossecute.storage.SignedTransmitter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SIGNED_TRANSMITTER_STORAGE =
        0x8566b709a423746963d200f6840e900d54ab8ebbe69c13e71ed1cbb86e81aa00;

    event SignedTransmitterInitialized();
    event RootRegistered(bytes32 indexed root);
    event LeafRelayed(bytes32 indexed leafHash, address indexed relayer);

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

    /// @notice Return this transmitter's namespaced signed-mode storage.
    /// @dev A fixed namespace avoids changing the base contracts' sequential layout when signed
    ///      authority and relay tracking are added.
    function _signedStorage() private pure returns (SignedTransmitterStorage storage $) {
        assembly ("memory-safe") {
            $.slot := SIGNED_TRANSMITTER_STORAGE
        }
    }

    function _requireSigned() private view {
        if (!_signedStorage().signed) revert NotSigned();
    }

    /// @inheritdoc ISignedTransmitterInit
    function initializeSigned() external {
        if (msg.sender != transceiver) revert NotTransceiver(msg.sender);
        SignedTransmitterStorage storage $ = _signedStorage();
        if ($.signed) revert AlreadySigned();
        $.signed = true;
        emit SignedTransmitterInitialized();
    }

    /* ================================ owner calls =============================== */

    /// @notice In signed mode, consume the Safe's staged call and transmit its signed evidence
    ///         with nested approvals.
    /// @dev The receiver needs the original authorization to verify independently of the
    ///      provider. Fees come from the conduit balance; plain mode uses the base send path.
    function sendMessage(bytes calldata recipient, bytes calldata payload, bytes[] calldata attributes)
        public
        payable
        override
        returns (bytes32 sendId)
    {
        if (!_signedStorage().signed) return super.sendMessage(recipient, payload, attributes);
        _checkOwner();
        (bytes memory to, bytes memory wire, bytes[] memory options) = SignedTransmitterLib.consumeMessage(msg.data);
        return _sendStandalone(to, wire, options);
    }

    /// @notice Quote, fund and transmit a standalone wire message while emitting the standard
    ///         send event.
    /// @dev Using the already built wire bytes ensures the amount paid matches the signed
    ///      payload the provider actually sends.
    function _sendStandalone(bytes memory recipient, bytes memory wire, bytes[] memory attributes)
        private
        returns (bytes32)
    {
        uint256 fee = _quoteStandalone(recipient, wire, attributes);
        _requireFunded(fee);
        emit MessageSent(bytes32(0), Erc7930.encodeEvm(block.chainid, address(this)), recipient, wire, fee, attributes);
        return _sendMessage(recipient, wire, attributes, fee);
    }

    /// @notice Validate the conduit recipient and quote the complete signed wire payload.
    /// @dev Only this conduit's reachable receiver is a valid route, and signatures must be
    ///      included in the provider's payload price.
    function _quoteStandalone(bytes memory recipient, bytes memory wire, bytes[] memory attributes)
        private
        view
        returns (uint256)
    {
        _requireOwnRecipient(recipient);
        return _quoteMessage(recipient, wire, attributes);
    }

    /// @notice In signed mode, consume the Safe's staged call and send the setup calls with the
    ///         Safe's live authority records; plain mode uses the base path.
    /// @dev Consuming the guard's record admits only a signed owner transaction, so a module
    ///      cannot bootstrap. Nothing from the record is sent: the destination stores the records
    ///      on the provider's authentication. A failed send reverts, as in plain mode.
    function bootstrap(bytes calldata payload, bytes[] calldata attributes)
        public
        payable
        override(TransmitterBase, ISignedTransmitter)
    {
        if (!_signedStorage().signed) return super.bootstrap(payload, attributes);
        _checkOwner();
        SignedTransmitterLib.consumeStaged();
        (bytes32 chainKey, bytes memory route, bytes memory body) = _signedBootstrap(payload);
        _markBootstrapped(chainKey, route);
        IConduitTransceiver t = IConduitTransceiver(transceiver);
        uint256 fee = t.quoteBootstrapSigned(chainKey, deployer, conduitSalt, body, attributes);
        _requireFunded(fee);
        // forge-lint: disable-next-line(arbitrary-send-eth) the write-once transceiver
        t.bootstrapSigned{value: fee}(chainKey, deployer, conduitSalt, body, attributes);
    }

    /// @notice The destination key, route and `SignedBootstrap` body for a bootstrap payload.
    /// @dev Shared by `bootstrap` and `quoteBootstrap`, so the quote prices the bytes sent.
    function _signedBootstrap(bytes calldata payload)
        private
        view
        returns (bytes32 chainKey, bytes memory route, bytes memory body)
    {
        bool typed;
        bytes memory setupCalls;
        (chainKey, route, typed, setupCalls) = _decodeBootstrap(payload);
        body = SignedTransmitterLib.bootstrapBody(chainKey, typed, setupCalls);
    }

    /// @notice Require the owner's root to be published by its current guard, then register it
    ///         once.
    /// @dev Later leaf relays need an explicit source registration, while keeping signatures
    ///      out of storage lets each relayer supply its own evidence.
    /// @inheritdoc ISignedTransmitter
    function registerRoot(bytes32 root) external onlyConduitOwner {
        _requireSigned();
        if (!ICrossecuteGuard(GuardDiscovery.transactionGuard(deployer)).isPublished(root)) {
            revert RootNotPublished(root);
        }
        SignedTransmitterStorage storage $ = _signedStorage();
        if ($.roots[root]) revert RootAlreadyRegistered(root);
        $.roots[root] = true;
        emit RootRegistered(root);
    }

    /// @notice Transfer ownership only in plain mode; reject changes in signed mode.
    /// @dev Signed receivers hold the creation-time Safe's authority, so the owner cannot move.
    function transferOwnership(address newOwner) public virtual override {
        if (_signedStorage().signed) revert OwnershipFixed();
        super.transferOwnership(newOwner);
    }

    /// @notice Allow plain-mode renunciation but reject it in signed mode.
    /// @dev Renouncing signed ownership would permanently disable the fixed Safe's owner-only
    ///      operations without changing destination authority.
    function renounceOwnership() public virtual override {
        if (_signedStorage().signed) revert OwnershipFixed();
        super.renounceOwnership();
    }

    /* ============================== permissionless ============================== */

    /// @notice Verify and transmit an unused authorized leaf, charging the caller and refunding
    ///         any synchronous excess.
    /// @dev The relay lock, used-leaf mark and final balance check prevent reentrant reuse or
    ///      spending preexisting conduit funds on another caller's relay.
    /// @inheritdoc ISignedTransmitter
    function relayLeaf(
        SafeTxEvidence calldata registrationEvidence,
        ExecutionLeaf calldata leaf,
        bytes32[] calldata proof
    ) external payable returns (bytes32 sendId) {
        (registrationEvidence, leaf, proof);
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

    /// @notice Quote the plain send path, reverting when this transmitter is in signed mode.
    /// @dev Signed transport fees depend on signatures absent from these arguments, so signed
    ///      callers must use `quoteSignedMessage` instead.
    function quoteMessage(bytes calldata recipient, bytes calldata payload, bytes[] calldata attributes)
        public
        view
        override
        returns (uint256)
    {
        if (_signedStorage().signed) revert SignedQuoteRequired();
        return super.quoteMessage(recipient, payload, attributes);
    }

    /// @notice Quote a bootstrap in either mode; a signed one prices the live records it would carry.
    function quoteBootstrap(bytes calldata payload, bytes[] calldata attributes)
        public
        view
        override
        returns (uint256)
    {
        if (!_signedStorage().signed) return super.quoteBootstrap(payload, attributes);
        (bytes32 chainKey,, bytes memory body) = _signedBootstrap(payload);
        return IConduitTransceiver(transceiver).quoteBootstrapSigned(chainKey, deployer, conduitSalt, body, attributes);
    }

    /// @notice Build the signed standalone payload and return the fee its send would pay.
    /// @dev Sharing the send builder, including live nested approval collection, prevents
    ///      quotes from omitting evidence bytes or pricing a different message.
    function quoteSignedMessage(SafeTxEvidence calldata evidence) external view returns (uint256) {
        _requireSigned();
        evidence;
        (bytes memory recipient, bytes memory wire, bytes[] memory attributes) =
            SignedTransmitterLib.quoteMessage(msg.data[4:]);
        return _quoteStandalone(recipient, wire, attributes);
    }

    /// @notice Return the fee for relaying the supplied signed registration, leaf and proof.
    /// @dev Sharing relay validation and wire construction avoids quoting an unregistered,
    ///      already relayed or differently encoded leaf as executable.
    function quoteRelay(
        SafeTxEvidence calldata registrationEvidence,
        ExecutionLeaf calldata leaf,
        bytes32[] calldata proof
    ) external view returns (uint256 fee) {
        (registrationEvidence, leaf, proof);
        (,,,, fee) = _relay();
    }

    /* ================================= builders ================================= */

    /// @notice Build the relay wire payload, check local root and leaf state, validate the
    ///         recipient and quote the fee.
    /// @dev The linked builder checks signatures and proofs; this wrapper adds the
    ///      transmitter's registration, replay and routing state for both quotes and sends.
    function _relay()
        private
        view
        returns (bytes32 leafHash, bytes memory destination, bytes[] memory attributes, bytes memory wire, uint256 fee)
    {
        _requireSigned();
        bytes32 root;
        (root, leafHash, destination, attributes, wire) = SignedTransmitterLib.relay(msg.data[4:]);
        SignedTransmitterStorage storage $ = _signedStorage();
        if (!$.roots[root]) revert RootNotRegistered(root);
        if ($.relayed[leafHash]) revert LeafAlreadyRelayed(leafHash);
        _requireOwnRecipient(destination);
        fee = _quoteMessage(destination, wire, attributes);
    }

    /// @notice Route provider refunds to the caller funding a leaf relay.
    /// @dev Quote and send must select the same recipient because provider metadata may affect
    ///      the price. Other entry points spend conduit funds and retain their refunds.
    function _refundTo() internal view override returns (address) {
        if (msg.sig == this.relayLeaf.selector || msg.sig == this.quoteRelay.selector) return msg.sender;
        return super._refundTo();
    }

    /* =================================== views ================================== */

    /// @inheritdoc ISignedTransmitterInit
    function isSigned() external view returns (bool) {
        return _signedStorage().signed;
    }

    /// @notice Report whether the owner has registered a root on this transmitter.
    /// @dev Relayers can check the source authorization prerequisite before paying to send a
    ///      leaf.
    function isRootRegistered(bytes32 root) external view returns (bool) {
        return _signedStorage().roots[root];
    }

    /// @notice Report whether this transmitter has already relayed the leaf hash.
    /// @dev A leaf may be relayed through this transmitter only once, so callers can avoid
    ///      duplicate source sends.
    function isLeafRelayed(bytes32 leafHash) external view returns (bool) {
        return _signedStorage().relayed[leafHash];
    }
}
