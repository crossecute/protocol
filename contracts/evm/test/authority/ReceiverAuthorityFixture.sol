// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {SafeTx, SignedSafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {AuthorityUpdate} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "@crossecute/safe-guard/authority/ISourceAuthorityGuard.sol";
import {Call} from "src/messaging/Call.sol";
import {AuthorityGraph} from "src/messaging/authority/AuthorityGraph.sol";
import {AuthorityRecognition} from "src/messaging/authority/AuthorityRecognition.sol";
import {ChildUpdate} from "src/messaging/authority/ChildUpdate.sol";
import {ReceiverAuthority} from "src/messaging/authority/ReceiverAuthority.sol";
import {ReceiverAuthorityTemplate} from "src/messaging/authority/ReceiverAuthorityTemplate.sol";
import {AuthorityUpdateEncoding} from "src/messaging/authority/AuthorityUpdateEncoding.sol";
import {SafeAuthorityRecord} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {NestedSafeApproval, SafeTxEvidence} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {SafeSigs, Sig} from "../signed/SignedFixtures.sol";

/// @dev Test-only hooks. Recognition uses placeholder guard and MultiSend addresses; step 5
///      replaces it. Votes are the template's own check over Safe 1.5.0 signature blobs.
contract ReceiverAuthorityFixture is ReceiverAuthorityTemplate {
    address internal constant GUARD = address(0x1234);
    address internal constant MULTISEND = address(0x5678);
    uint256 internal immutable _sourceChainId;
    address internal immutable _sourceSafe;
    bool public busy;

    constructor(uint256 sourceChainId, address sourceSafe) {
        (_sourceChainId, _sourceSafe) = (sourceChainId, sourceSafe);
    }

    function setBusy(bool value) external {
        busy = value;
    }

    /// @dev Stands in for the bootstrap that seeds a receiver.
    function seed(bytes32 updateHead, AuthorityGraph calldata initial) external {
        _seedAuthority(updateHead, initial);
    }

    function _recognizeUpdate(uint256, address sourceSafe, SafeTxEvidence calldata e)
        internal
        pure
        override
        returns (ReceiverAuthority.RecognizedUpdate memory)
    {
        return AuthorityRecognition.recognize(GUARD, MULTISEND, sourceSafe, e.signedSafeTx.safeTx);
    }

    function _authoritySource() internal view override returns (uint256, address) {
        return (_sourceChainId, _sourceSafe);
    }

    function _requireAuthorityContextIdle() internal view override {
        require(!busy, "application context busy");
    }
}

/// @dev Source-call builders and signers shared by the receiver authority suites.
abstract contract ReceiverAuthorityTestBase is Test {
    uint256 internal constant CHAIN = 1;
    address internal constant GUARD = address(0x1234);
    address internal constant MULTISEND = address(0x5678);
    address internal constant SENTINEL = address(1);

    /// @dev An activation names only its graph hash; receivers reject it by kind.
    function _activationTx(uint256 chain, AuthorityGraph memory initial) internal pure returns (SafeTx memory tx_) {
        tx_.to = GUARD;
        tx_.data = abi.encodeWithSelector(
            ISourceAuthorityGuard.activate.selector, AuthorityUpdateEncoding.graphHash(chain, initial)
        );
    }

    function _ownershipTx(address safe, AuthorityUpdate memory update, Call[] memory mutations, uint256 nonce)
        internal
        pure
        returns (SafeTx memory tx_)
    {
        tx_.to = MULTISEND;
        tx_.operation = 1;
        tx_.data = AuthorityUpdateEncoding.ownershipBatchData(GUARD, safe, update, mutations);
        tx_.nonce = nonce;
    }

    function _selectionTx(AuthorityUpdate memory update, uint256 nonce) internal pure returns (SafeTx memory tx_) {
        tx_.to = GUARD;
        tx_.data = abi.encodeCall(ISourceAuthorityGuard.selectAuthority, (update));
        tx_.nonce = nonce;
    }

    /// @dev A Safe 1.5.0 signature blob over the SafeTx hash, with no nested approvals.
    function _signed(SafeTx memory tx_, address safe, uint256 chain, Sig[] memory sigs)
        internal
        pure
        returns (SafeTxEvidence memory)
    {
        bytes memory signatures = SafeSigs.blob(sigs, SafeHashes.transactionHash(tx_, safe, chain));
        return SafeTxEvidence(SignedSafeTx(tx_, signatures), new NestedSafeApproval[](0));
    }

    /// @dev One ECDSA entry per key.
    function _sign(SafeTx memory tx_, address safe, uint256 chain, uint256[] memory keys)
        internal
        pure
        returns (SafeTxEvidence memory)
    {
        Sig[] memory sigs = new Sig[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            sigs[i] = SafeSigs.eoa(keys[i]);
        }
        return _signed(tx_, safe, chain, sigs);
    }

    function _sign(SafeTx memory tx_, address safe, uint256 chain, uint256 key)
        internal
        pure
        returns (SafeTxEvidence memory)
    {
        return _sign(tx_, safe, chain, _keys(key));
    }

    /// @dev Signed by Safe owner `child` alone, through child's EOA owner `key`.
    function _signByChild(SafeTx memory tx_, address safe, address child, uint256 key)
        internal
        pure
        returns (SafeTxEvidence memory)
    {
        bytes32 digest = SafeHashes.transactionHash(tx_, safe, CHAIN);
        return _signed(tx_, safe, CHAIN, SafeSigs.one(_inline(child, digest, SafeSigs.one(SafeSigs.eoa(key)))));
    }

    /// @dev Safe owner `child`'s entry over `parentHash`, carrying child's own blob inline.
    function _inline(address child, bytes32 parentHash, Sig[] memory childSigs) internal pure returns (Sig memory) {
        return SafeSigs.nested(child, SafeSigs.blob(childSigs, _nestedHash(parentHash, child)));
    }

    /// @dev The Safe message hash `child` signs to approve `parentHash`.
    function _nestedHash(bytes32 parentHash, address child) internal pure returns (bytes32) {
        return SafeHashes.messageHash(abi.encode(parentHash), child, CHAIN);
    }

    function _childUpdate(SafeTxEvidence memory e, AuthorityGraph memory childGraph)
        internal
        pure
        returns (ChildUpdate memory)
    {
        SafeAuthorityRecord memory newRecord = childGraph.nodes[0].record;
        return ChildUpdate(newRecord.safe, e, newRecord, AuthorityUpdateEncoding.entries(childGraph));
    }

    function _hash(SafeTxEvidence memory e, address safe) internal pure returns (bytes32) {
        return SafeHashes.transactionHash(e.signedSafeTx.safeTx, safe, CHAIN);
    }

    function _keys(uint256 key) internal pure returns (uint256[] memory keys) {
        keys = new uint256[](1);
        keys[0] = key;
    }

    function _keys(uint256 a, uint256 b) internal pure returns (uint256[] memory keys) {
        keys = new uint256[](2);
        (keys[0], keys[1]) = (a, b);
    }
}
