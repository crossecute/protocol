// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICrossecuteGuard, SignedSafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {GuardDiscovery} from "@crossecute/safe-guard/GuardDiscovery.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {ISourceAuthorityGuard} from "@crossecute/safe-guard/authority/ISourceAuthorityGuard.sol";
import {AuthoritySelection} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {AuthorityGraph} from "src/messaging/authority/AuthorityGraph.sol";
import {ChildUpdate} from "src/messaging/authority/ChildUpdate.sol";
import {ReceiverAuthority} from "src/messaging/authority/ReceiverAuthority.sol";
import {IConduitTransceiver} from "src/messaging/outbound/TransmitterBase.sol";
import {Payload} from "src/messaging/Payload.sol";
import {DispatchLeaves} from "src/messaging/signed/DispatchLeaves.sol";
import {NestedApprovalCollector} from "src/messaging/signed/NestedApprovalCollector.sol";
import {SignedDispatchCalls} from "src/messaging/signed/SignedDispatchCalls.sol";
import {
    ExecutionLeaf,
    SafeTxEvidence,
    SignedBootstrap,
    WIRE_STANDALONE,
    WIRE_MERKLE,
    WIRE_AUTHORITY
} from "src/messaging/signed/types/SignedDispatchTypes.sol";

/// @dev Safe 1.5.0's signature check against its live owners and threshold.
interface ISafeSignatures {
    /// @dev A permissionless registration relay did not execute the signed Safe transaction
    ///      itself, so its source authorization must be checked before transmission.
    function checkSignatures(address executor, bytes32 dataHash, bytes memory signatures) external view;
}

/// @dev The transmitter's own getters, read back by self-call so this library does not depend on
///      its storage layout.
interface ISignedTransmitterView {
    function deployer() external view returns (address);
    function transceiver() external view returns (address);
}

/// @notice The wire builders of `SignedTransmitter`. External, so linked and called by
///         `DELEGATECALL`: `address(this)` is the transmitter, which is the signed target and the
///         guard's `consume` caller. Takes and returns raw ABI bytes so the transmitter carries
///         no encoder for the nested structs.
/// @dev Each send and its quote share one internal builder, so they price the same bytes.
library SignedTransmitterLib {
    /// @notice Consume the owner's staged transaction and build its standalone wire message and
    ///         route.
    /// @dev Capturing evidence during the Safe call preserves the exact signed calldata and attaches
    ///      approvals the destination cannot read from source guards.
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
    /// @param args `abi.encode(SafeTxEvidence)`.
    function quoteMessage(bytes calldata args)
        external
        view
        returns (bytes memory recipient, bytes memory wire, bytes[] memory attributes)
    {
        return _standalone(ISignedTransmitterView(address(this)).deployer(), abi.decode(args, (SafeTxEvidence)));
    }

    /// @dev The destination reports its receiver or is not EVM; signed receivers are created
    ///      only where the home derives them.
    error SignedReceiverNotDerivable(bytes32 destinationChainKey);
    error NoSignedAuthority(address safe);
    error BootstrapAuthorityMismatch();

    /// @notice Consume the owner's staged transaction without reading it.
    /// @dev Consumption admits only a signed owner execution targeting this transmitter.
    function consumeStaged() external {
        address safe = ISignedTransmitterView(address(this)).deployer();
        // forge-lint: disable-next-line(unused-return) consuming is the check; nothing from the record is sent
        ICrossecuteGuard(GuardDiscovery.transactionGuard(safe)).consume(safe);
    }

    /// @notice Check the supplied bootstrap against the guard's current selection.
    /// @param typed Whether the destination executes `Call[]`, as `_decodeBootstrap` reports.
    function bootstrapBody(bytes32 chainKey, bool typed, bytes memory body) external view returns (bytes memory) {
        ISignedTransmitterView self = ISignedTransmitterView(address(this));
        IConduitTransceiver t = IConduitTransceiver(self.transceiver());
        if (!typed || t.reportsReceiver(chainKey)) revert SignedReceiverNotDerivable(chainKey);
        return _bootstrapAuthority(self.deployer(), body);
    }

    function _bootstrapAuthority(address safe, bytes memory body) private view returns (bytes memory) {
        SignedBootstrap memory bootstrap = abi.decode(body, (SignedBootstrap));
        Payload.decodeCallsFromMemory(bootstrap.setupCalls);
        address guard = GuardDiscovery.transactionGuard(safe);
        AuthoritySelection memory selected = ISourceAuthorityGuard(guard).selection(safe);
        if (selected.authorityHash == bytes32(0)) revert NoSignedAuthority(safe);
        if (
            guard != bootstrap.guard || selected.updateHead != bootstrap.updateHead
                || selected.authorityHash != ReceiverAuthority.encodedGraphHash(block.chainid, bootstrap.authority)
        ) revert BootstrapAuthorityMismatch();
        return body;
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

    error AuthorityNotPublished(bytes32 updateHead);

    /// @notice Require the exact portable evidence published by source execution.
    /// @dev Live owners may have rotated since publication; recollecting approvals would change
    ///      the portable quorum that the guard verified. Destinations still verify independently.
    function authority(bytes memory submission) external view returns (bytes32 head, bytes memory wire) {
        (SafeTxEvidence memory evidence,,) = abi.decode(submission, (SafeTxEvidence, AuthorityGraph, ChildUpdate[]));
        address safe = ISignedTransmitterView(address(this)).deployer();
        head = SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, safe, block.chainid);
        if (
            ISourceAuthorityGuard(GuardDiscovery.transactionGuard(safe)).publishedAuthority(safe, head)
                != keccak256(submission)
        ) {
            revert AuthorityNotPublished(head);
        }
        wire = abi.encode(WIRE_AUTHORITY, submission);
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

    /// @dev The destination cannot query source guard state, and the payload must carry exactly the
    ///      approvals the source signature blob requires.
    function _collect(address safe, SafeTxEvidence memory evidence) private view returns (bytes32 safeTxHash) {
        safeTxHash = SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, safe, block.chainid);
        evidence.nestedApprovals = NestedApprovalCollector.collect(safe, safeTxHash, evidence.signedSafeTx.signatures);
    }
}
