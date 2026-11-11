// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICrossecuteGuard, SignedSafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {GuardDiscovery} from "@crossecute/safe-guard/GuardDiscovery.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {IConduitTransceiver} from "src/messaging/outbound/TransmitterBase.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {DispatchLeaves} from "src/messaging/signed/DispatchLeaves.sol";
import {NestedApprovalCollector} from "src/messaging/signed/NestedApprovalCollector.sol";
import {SignedDispatchCalls} from "src/messaging/signed/SignedDispatchCalls.sol";
import {SafeAuthorityRecord} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {
    ExecutionLeaf,
    BootstrapLeaf,
    SafeTxEvidence,
    SignedBootstrap,
    WIRE_STANDALONE,
    WIRE_MERKLE
} from "src/messaging/signed/types/SignedDispatchTypes.sol";

/// @dev Safe 1.5.0's signature check against its live owners and threshold.
interface ISafeSignatures {
    /// @notice Ask the source Safe to validate signatures against its live owners and
    ///         threshold.
    /// @dev A permissionless registration relay did not execute the signed Safe transaction
    ///      itself, so its source authorization must be checked before transmission.
    function checkSignatures(address executor, bytes32 dataHash, bytes memory signatures) external view;
}

/// @dev The transmitter's own getters, read back by self-call so this library does not depend on
///      its storage layout.
interface ISignedTransmitterView {
    /// @notice Return the creation-time owner Safe used as the signed transaction's domain.
    /// @dev The linked builder needs the fixed source Safe without depending on the
    ///      transmitter's storage layout.
    function deployer() external view returns (address);
    /// @notice Return the transmitter's parent transceiver.
    /// @dev Bootstrap routing, receiver prediction and provider fee queries must use that fixed
    ///      parent.
    function transceiver() external view returns (address);
    /// @notice Return the user's conduit salt.
    /// @dev Receiver prediction must preserve the salt selected at conduit creation rather than
    ///      inventing a new destination address.
    function conduitSalt() external view returns (bytes32);
    /// @notice Return the transmitter's creation-graph commitment.
    /// @dev The builder includes the same authority commitment when predicting the destination
    ///      receiver.
    function authorityGraph() external view returns (bytes32);
    /// @notice Return the transmitter's encoded creation authority records.
    /// @dev Signed bootstraps carry those records so the receiver can reconstruct its fixed
    ///      verification authority.
    function creationRecords() external view returns (bytes memory);
    /// @notice Report whether this conduit has already bootstrapped a destination chain.
    /// @dev The builder must reject a new bootstrap for a destination the transmitter already
    ///      considers initialized.
    function isBootstrapped(bytes32 chainKey) external view returns (bool);
}

/// @notice The wire builders of `SignedTransmitter`. External, so linked and called by
///         `DELEGATECALL`: `address(this)` is the transmitter, which is the signed target and the
///         guard's `consume` caller. Takes and returns raw ABI bytes so the transmitter carries
///         no encoder for the nested structs.
/// @dev Each send and its quote share one internal builder, so they price the same bytes.
library SignedTransmitterLib {
    /// @notice Consume the owner's staged transaction and build its standalone wire message and
    ///         route.
    /// @dev Capturing evidence during the Safe call preserves the exact signed calldata and
    ///      attaches approvals the destination cannot read from source guards.
    /// @param callData The transmitter's `msg.data`, which the Safe signed.
    function consumeMessage(bytes calldata callData)
        external
        returns (bytes memory recipient, bytes memory wire, bytes[] memory attributes)
    {
        address safe = ISignedTransmitterView(address(this)).deployer();
        return _standalone(safe, _consume(safe, callData));
    }

    /// @notice Build a standalone message from supplied evidence without consuming the guard's
    ///         staged transaction.
    /// @dev Reusing the send builder lets the transmitter quote the same signature and approval
    ///      bytes it would transmit.
    /// @param args `abi.encode(SafeTxEvidence)`.
    function quoteMessage(bytes calldata args)
        external
        view
        returns (bytes memory recipient, bytes memory wire, bytes[] memory attributes)
    {
        return _standalone(ISignedTransmitterView(address(this)).deployer(), abi.decode(args, (SafeTxEvidence)));
    }

    error AlreadyBootstrapped(bytes32 destinationChainKey);
    /// @dev The destination reports its receiver, and no report carries the graph yet.
    error SignedReceiverNotDerivable(bytes32 destinationChainKey);
    error WrongBootstrapTarget(bytes destination);

    /// @notice Consume the staged bootstrap and build its body, destination key, route and
    ///         attributes.
    /// @dev The transceiver needs both signed setup authorization and creation records to
    ///      derive and initialize the destination receiver.
    function consumeBootstrap(bytes calldata callData)
        external
        returns (bytes memory body, bytes32 chainKey, bytes memory route, bytes[] memory attributes)
    {
        address safe = ISignedTransmitterView(address(this)).deployer();
        return _bootstrap(safe, _consume(safe, callData));
    }

    /// @notice Build the bootstrap body and route from supplied evidence without consuming
    ///         guard state.
    /// @dev The quote path needs the same encoded body as the send, including any nested
    ///      approvals and authority records.
    /// @param args `abi.encode(SafeTxEvidence)`.
    function quoteBootstrap(bytes calldata args)
        external
        view
        returns (bytes memory body, bytes32 chainKey, bytes memory route, bytes[] memory attributes)
    {
        return _bootstrap(ISignedTransmitterView(address(this)).deployer(), abi.decode(args, (SafeTxEvidence)));
    }

    /// @notice Recheck and return the destination route and attributes of an encoded bootstrap
    ///         body.
    /// @dev A permissionless retry must still target a derivable, not-yet-bootstrapped receiver
    ///      and must not send an expired authorization.
    function bootstrapTarget(bytes calldata body)
        external
        view
        returns (bytes32 chainKey, bytes memory route, bytes[] memory attributes)
    {
        return _target(abi.decode(body, (SignedBootstrap)).evidence);
    }

    /// @notice Validate the signed root registration and leaf proof, then build the Merkle wire
    ///         payload.
    /// @dev A relayer cannot rely on source transaction execution, so the live Safe checks the
    ///      signatures here. Local root-registration and used-leaf state are checked by the
    ///      transmitter wrapper.
    /// @param args `abi.encode(SafeTxEvidence, ExecutionLeaf, bytes32[])`, as `relayLeaf` takes.
    function relay(bytes calldata args)
        external
        view
        returns (bytes32 root, bytes32 leafHash, bytes memory destination, bytes[] memory attributes, bytes memory wire)
    {
        (SafeTxEvidence memory evidence, ExecutionLeaf memory leaf, bytes32[] memory proof) =
            abi.decode(args, (SafeTxEvidence, ExecutionLeaf, bytes32[]));
        address safe = ISignedTransmitterView(address(this)).deployer();
        SignedDispatchCalls.requireSourceCall(evidence.signedSafeTx.safeTx, address(this));
        root = SignedDispatchCalls.registeredRoot(evidence.signedSafeTx.safeTx);
        leafHash = DispatchLeaves.hash(leaf);
        DispatchLeaves.requireProof(proof, root, leafHash);

        bytes32 safeTxHash = _collect(safe, evidence);
        ISafeSignatures(safe).checkSignatures(address(0), safeTxHash, evidence.signedSafeTx.signatures);
        wire = abi.encode(WIRE_MERKLE, evidence, leaf, proof);
        return (root, leafHash, leaf.destination, leaf.attributes, wire);
    }

    /* ================================= internals ================================ */

    /// @notice Read the Safe's staged transaction and restore its data from the current call.
    /// @dev The guard omits the calldata from its staged return; restoring the bytes the Safe
    ///      called lets destination verification hash the original signed transaction.
    function _consume(address safe, bytes calldata callData) private returns (SafeTxEvidence memory evidence) {
        SignedSafeTx memory staged = ICrossecuteGuard(GuardDiscovery.transactionGuard(safe)).consume(safe);
        staged.safeTx.data = callData;
        evidence.signedSafeTx = staged;
    }

    /// @notice Check the signed source call, decode a nonempty payload, collect approvals and
    ///         encode the standalone wire format.
    /// @dev Both quoting and sending need one builder so signatures, recipient and provider
    ///      attributes describe the same transmitted message.
    function _standalone(address safe, SafeTxEvidence memory evidence)
        private
        view
        returns (bytes memory recipient, bytes memory wire, bytes[] memory attributes)
    {
        SignedDispatchCalls.requireSourceCall(evidence.signedSafeTx.safeTx, address(this));
        bytes memory payload;
        (recipient, payload, attributes) = SignedDispatchCalls.sendMessageArgs(evidence.signedSafeTx.safeTx.data);
        if (payload.length == 0) revert SignedDispatchCalls.EmptySignedPayload();
        _collect(safe, evidence);
        wire = abi.encode(WIRE_STANDALONE, evidence);
    }

    /// @notice Validate the bootstrap target, collect nested approvals and package the creation
    ///         records with its evidence.
    /// @dev The receiver needs both authorization and its complete authority snapshot to
    ///      perform initialization independently of the provider.
    function _bootstrap(address safe, SafeTxEvidence memory evidence)
        private
        view
        returns (bytes memory body, bytes32 chainKey, bytes memory route, bytes[] memory attributes)
    {
        (chainKey, route, attributes) = _target(evidence);
        _collect(safe, evidence);
        bytes memory records = ISignedTransmitterView(address(this)).creationRecords();
        body = abi.encode(SignedBootstrap(evidence, abi.decode(records, (SafeAuthorityRecord[]))));
    }

    /// @notice Validate the bootstrap proof and window, derive its route and match its
    ///         destination to the predicted receiver.
    /// @dev Reject existing or nonderivable destinations so setup cannot initialize an
    ///      unrelated receiver. A future window is allowed because delivery may happen later;
    ///      an expired window is not.
    function _target(SafeTxEvidence memory evidence)
        private
        view
        returns (bytes32 chainKey, bytes memory route, bytes[] memory attributes)
    {
        SignedDispatchCalls.requireSourceCall(evidence.signedSafeTx.safeTx, address(this));
        bytes32 root;
        BootstrapLeaf memory leaf;
        bytes32[] memory proof;
        (root, leaf, proof, attributes) = SignedDispatchCalls.bootstrapArgs(evidence.signedSafeTx.safeTx.data);
        DispatchLeaves.requireProof(proof, root, DispatchLeaves.hash(leaf));
        // forge-lint: disable-next-line(block-timestamp) an expired window cannot initialize anywhere later
        if (leaf.validAfter > leaf.deadline || block.timestamp > leaf.deadline) {
            revert SignedDispatchCalls.WindowClosed(leaf.validAfter, leaf.deadline);
        }

        Erc7930.Interop memory io = Erc7930.parseStrict(leaf.destination);
        Erc7930.evmChainId(io);
        route = Erc7930.encodeChainId(io.chainType, io.chainRef);
        chainKey = keccak256(route);

        ISignedTransmitterView self = ISignedTransmitterView(address(this));
        if (self.isBootstrapped(chainKey)) revert AlreadyBootstrapped(chainKey);
        IConduitTransceiver t = IConduitTransceiver(self.transceiver());
        if (t.reportsReceiver(chainKey)) revert SignedReceiverNotDerivable(chainKey);
        bytes memory predicted = t.predictReceiver(chainKey, self.deployer(), self.conduitSalt(), self.authorityGraph());
        if (keccak256(io.addr) != keccak256(predicted)) revert WrongBootstrapTarget(leaf.destination);
    }

    /// @notice Hash the signed Safe transaction and replace its nested approvals with evidence
    ///         read from current guards.
    /// @dev The destination cannot query source guard state, and the payload must carry exactly
    ///      the approvals required by the source signature blob.
    function _collect(address safe, SafeTxEvidence memory evidence) private view returns (bytes32 safeTxHash) {
        safeTxHash = SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, safe, block.chainid);
        evidence.nestedApprovals = NestedApprovalCollector.collect(safe, safeTxHash, evidence.signedSafeTx.signatures);
    }
}
