// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {SafeTx, SignedSafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {AuthorityUpdate, SafeCreationProof} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "@crossecute/safe-guard/authority/ISourceAuthorityGuard.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {Call} from "src/messaging/Call.sol";
import {AuthorityGraph} from "src/messaging/authority/AuthorityGraph.sol";
import {ChildUpdate} from "src/messaging/authority/ChildUpdate.sol";
import {AuthorityRegistryTemplate} from "src/messaging/authority/AuthorityRegistryTemplate.sol";
import {AuthorityUpdateEncoding} from "src/messaging/authority/AuthorityUpdateEncoding.sol";
import {SafeCreation} from "src/messaging/authority/SafeCreation.sol";
import {SAFE_PROXY_FACTORY, SAFE_PROXY_INITCODE_HASH, SAFE_SINGLETON} from "src/messaging/authority/SafeDeployment.sol";
import {SafeAuthorityRecord} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {NestedSafeApproval, SafeTxEvidence} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {SafeSigs, Sig} from "../signed/SignedFixtures.sol";

/// @dev Test-only hooks. Recognition uses placeholder guard and MultiSend addresses; step 5
///      replaces it. Votes are the template's own check over Safe 1.5.0 signature blobs.
contract AuthorityRegistryFixture is AuthorityRegistryTemplate {
    address internal constant GUARD = address(0x1234);
    address internal constant MULTISEND = address(0x5678);
    bool public busy;

    function setBusy(bool value) external {
        busy = value;
    }

    function _recognizeUpdate(uint256, address sourceSafe, SafeTxEvidence calldata e)
        internal
        pure
        override
        returns (RecognizedUpdate memory r)
    {
        SafeTx calldata tx_ = e.signedSafeTx.safeTx;
        require(tx_.value == 0, "wrong source call");
        if (tx_.to == MULTISEND && tx_.operation == 1) {
            r.kind = UpdateKind.OwnershipChange;
            (r.update, r.mutations) = AuthorityUpdateEncoding.decodeOwnershipBatch(GUARD, sourceSafe, tx_.data);
            return r;
        }
        require(tx_.to == GUARD && tx_.operation == 0, "wrong source call");
        bytes4 selector = bytes4(tx_.data);
        if (selector == ISourceAuthorityGuard.activate.selector) {
            r.kind = UpdateKind.Activation;
            (r.update.newAuthorityHash, r.creation) = abi.decode(tx_.data[4:], (bytes32, SafeCreationProof));
            return r;
        }
        require(selector == ISourceAuthorityGuard.selectAuthority.selector, "wrong selector");
        r.kind = UpdateKind.Selection;
        r.update = abi.decode(tx_.data[4:], (AuthorityUpdate));
    }

    function _requireAuthorityContextIdle(uint256, address) internal view override {
        require(!busy, "application context busy");
    }
}

/// @dev Source-call builders and signers shared by the registry suites.
abstract contract AuthorityRegistryTestBase is Test {
    uint256 internal constant CHAIN = 1;
    address internal constant GUARD = address(0x1234);
    address internal constant MULTISEND = address(0x5678);
    address internal constant SENTINEL = address(1);

    function _creation(address[] memory owners, uint256 threshold) internal pure returns (SafeCreationProof memory) {
        bytes memory initializer = abi.encodeWithSelector(
            SafeCreation.SETUP, owners, threshold, address(0), "", address(0), address(0), 0, address(0)
        );
        return SafeCreationProof(SAFE_SINGLETON, initializer, 0);
    }

    /// @dev The factory's plain-salt address, derived here independently of SafeCreation.
    function _safeAddress(SafeCreationProof memory creation) internal pure returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(keccak256(creation.initializer), creation.saltNonce));
        return AddressDerive.create2(SAFE_PROXY_FACTORY, salt, SAFE_PROXY_INITCODE_HASH);
    }

    function _activationTx(uint256 chain, AuthorityGraph memory initial, SafeCreationProof memory creation)
        internal
        pure
        returns (SafeTx memory tx_)
    {
        tx_.to = GUARD;
        tx_.data = abi.encodeCall(
            ISourceAuthorityGuard.activate, (AuthorityUpdateEncoding.graphHash(chain, initial), creation)
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
