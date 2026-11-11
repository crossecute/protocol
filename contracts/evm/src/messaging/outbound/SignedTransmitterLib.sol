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
    function checkSignatures(address executor, bytes32 dataHash, bytes memory signatures) external view;
}

/// @dev The transmitter's own getters, read back by self-call so this library does not depend on
///      its storage layout.
interface ISignedTransmitterView {
    function deployer() external view returns (address);
    function transceiver() external view returns (address);
    function conduitSalt() external view returns (bytes32);
    function authorityGraph() external view returns (bytes32);
    function creationRecords() external view returns (bytes memory);
    function isBootstrapped(bytes32 chainKey) external view returns (bool);
}

/// @notice The wire builders of `SignedTransmitter`. External, so linked and called by
///         `DELEGATECALL`: `address(this)` is the transmitter, which is the signed target and the
///         guard's `consume` caller. Takes and returns raw ABI bytes so the transmitter carries
///         no encoder for the nested structs.
/// @dev Each send and its quote share one internal builder, so they price the same bytes.
library SignedTransmitterLib {
    /// @notice The owner Safe's staged `sendMessage`, as the standalone wire message.
    /// @param callData The transmitter's `msg.data`, which the Safe signed.
    function consumeMessage(bytes calldata callData)
        external
        returns (bytes memory recipient, bytes memory wire, bytes[] memory attributes)
    {
        address safe = ISignedTransmitterView(address(this)).deployer();
        return _standalone(safe, _consume(safe, callData));
    }

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

    /// @notice The owner Safe's staged `bootstrap`, as the body `bootstrapSigned` carries, and
    ///         where it goes.
    function consumeBootstrap(bytes calldata callData)
        external
        returns (bytes memory body, bytes32 chainKey, bytes memory route, bytes[] memory attributes)
    {
        address safe = ISignedTransmitterView(address(this)).deployer();
        return _bootstrap(safe, _consume(safe, callData));
    }

    /// @param args `abi.encode(SafeTxEvidence)`.
    function quoteBootstrap(bytes calldata args)
        external
        view
        returns (bytes memory body, bytes32 chainKey, bytes memory route, bytes[] memory attributes)
    {
        return _bootstrap(ISignedTransmitterView(address(this)).deployer(), abi.decode(args, (SafeTxEvidence)));
    }

    /// @notice Where a retry of a logged bootstrap `body` sends, if it still could initialize.
    function bootstrapTarget(bytes calldata body)
        external
        view
        returns (bytes32 chainKey, bytes memory route, bytes[] memory attributes)
    {
        return _target(abi.decode(body, (SignedBootstrap)).evidence);
    }

    /// @notice The Merkle wire message for one leaf, after checking the signed registration
    ///         against the owner Safe's live authority and the leaf against its root.
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

    /// @dev The staged record, with `data` restored from the call the Safe made.
    function _consume(address safe, bytes calldata callData) private returns (SafeTxEvidence memory evidence) {
        SignedSafeTx memory staged = ICrossecuteGuard(GuardDiscovery.transactionGuard(safe)).consume(safe);
        staged.safeTx.data = callData;
        evidence.signedSafeTx = staged;
    }

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

    /// @dev A signed bootstrap that could still initialize its receiver: an open or future window,
    ///      a destination with none yet, and the receiver this chain predicts for the conduit. An
    ///      early window is allowed, since delivery may land later.
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

    /// @dev Replaces `evidence.nestedApprovals` with what the owner Safe's signatures need, read from the
    ///      guards, and returns the Safe transaction hash.
    function _collect(address safe, SafeTxEvidence memory evidence) private view returns (bytes32 safeTxHash) {
        safeTxHash = SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, safe, block.chainid);
        evidence.nestedApprovals = NestedApprovalCollector.collect(safe, safeTxHash, evidence.signedSafeTx.signatures);
    }
}
