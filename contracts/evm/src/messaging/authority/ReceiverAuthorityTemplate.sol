// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AuthoritySelection} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {SafeAuthorityRecord} from "../signed/types/SafeAuthorityTypes.sol";
import {SafeTxEvidence} from "../signed/types/SignedDispatchTypes.sol";
import {AuthorityGraph} from "./AuthorityGraph.sol";
import {ChildUpdate} from "./ChildUpdate.sol";
import {IReceiverAuthority} from "./IReceiverAuthority.sol";
import {ReceiverAuthority} from "./ReceiverAuthority.sol";

/// @notice Non-deployable #109 authority of one signed receiver over the linked
///         `ReceiverAuthority` library.
/// @dev Source-call recognition, the source identity and context locking are abstract hooks.
///      Current receivers do not inherit this, and it is absent from deployment scripts.
/// @dev State is ERC-7201 namespaced so a receiver can add it without extending its base's
///      sequential layout (R8.2).
abstract contract ReceiverAuthorityTemplate is IReceiverAuthority {
    using ReceiverAuthority for ReceiverAuthority.State;

    // keccak256(abi.encode(uint256(keccak256("crossecute.storage.ReceiverAuthority")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RECEIVER_AUTHORITY_STORAGE =
        0x6d0209d4e0e1a183e61dfc4b31b842ce90252036bca12cdc82cfe5ab3e835800;

    bool private _submitting;

    error AuthoritySubmissionReentered();

    function _authority() private pure returns (ReceiverAuthority.State storage $) {
        assembly ("memory-safe") {
            $.slot := RECEIVER_AUTHORITY_STORAGE
        }
    }

    /// @inheritdoc IReceiverAuthority
    function selection() public view returns (AuthoritySelection memory) {
        return _authority().selection;
    }

    /// @inheritdoc IReceiverAuthority
    function graph(bytes32 authorityHash) public view returns (AuthorityGraph memory) {
        return _authority().graph(authorityHash);
    }

    /// @inheritdoc IReceiverAuthority
    function record(bytes32 recordHash) public view returns (SafeAuthorityRecord memory) {
        return _authority().record(recordHash);
    }

    /// @notice Store the head and selected graph a bootstrap carried, once.
    function _seedAuthority(bytes32 updateHead, AuthorityGraph memory initial) internal {
        (uint256 sourceChainId, address sourceSafe) = _authoritySource();
        bytes32 authorityHash = _authority().seed(sourceChainId, sourceSafe, updateHead, initial);
        emit AuthoritySelected(updateHead, authorityHash);
    }

    /// @inheritdoc IReceiverAuthority
    function submitAuthority(
        SafeTxEvidence calldata evidence,
        AuthorityGraph calldata newGraph,
        ChildUpdate[] calldata childUpdates
    ) external {
        if (_submitting) revert AuthoritySubmissionReentered();
        _submitting = true;
        _requireAuthorityContextIdle();
        (uint256 sourceChainId, address sourceSafe) = _authoritySource();
        ReceiverAuthority.Recognized memory recognized;
        recognized.root = _recognizeUpdate(sourceChainId, sourceSafe, evidence);
        recognized.children = new ReceiverAuthority.RecognizedUpdate[](childUpdates.length);
        for (uint256 i; i < childUpdates.length; ++i) {
            recognized.children[i] =
                _recognizeUpdate(sourceChainId, childUpdates[i].sourceSafe, childUpdates[i].evidence);
        }
        // forge-lint: disable-start(reentrancy-no-eth) a DELEGATECALL into the linked library, under the lock
        bytes32 updateHash =
            _authority().applyUpdate(sourceChainId, sourceSafe, evidence, newGraph, childUpdates, recognized);
        // forge-lint: disable-end(reentrancy-no-eth)
        emit AuthoritySelected(updateHash, _authority().selection.authorityHash);
        _submitting = false;
    }

    /// @dev Recognize the signed source call of `sourceSafe`, the root or a child, so an activation
    ///      can be rejected by kind. No signature check.
    function _recognizeUpdate(uint256 sourceChainId, address sourceSafe, SafeTxEvidence calldata evidence)
        internal
        view
        virtual
        returns (ReceiverAuthority.RecognizedUpdate memory);

    /// @dev The receiver's source chain and owner Safe.
    function _authoritySource() internal view virtual returns (uint256 sourceChainId, address sourceSafe);

    /// @dev Concrete integration must share application-execution locking across providers.
    function _requireAuthorityContextIdle() internal view virtual;
}
