// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
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
import {OWNER_EOA, OWNER_SAFE, SafeAuthorityRecord} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {NestedSafeApproval, SafeTxEvidence} from "src/messaging/signed/types/SignedDispatchTypes.sol";

/// @dev Test-only hooks. Recognition uses placeholder guard and MultiSend addresses. The vote
///      mock is not Safe's signature format: signatures are 65-byte ECDSA entries by distinct
///      ascending EOA owners over the SafeTx hash, and each nested approval is one vote by a
///      Safe owner whose single ECDSA signature over messageHash is by an EOA owner of the
///      record _voterRecord returns. Steps 4 and 5 replace both hooks.
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

    function _verifyVotes(
        uint256 chain,
        address safe,
        SafeTxEvidence calldata e,
        SafeAuthorityRecord memory voters,
        VoterPositions memory positions
    ) internal pure override {
        bytes32 digest = SafeHashes.transactionHash(e.signedSafeTx.safeTx, safe, chain);
        bytes calldata signatures = e.signedSafeTx.signatures;
        require(signatures.length % 65 == 0, "fixture signatures");
        uint256 votes;
        address last;
        for (uint256 i; i < signatures.length; i += 65) {
            address signer = ECDSA.recover(digest, signatures[i:i + 65]);
            require(signer > last && _isOwner(voters, signer, OWNER_EOA), "wrong current signer");
            last = signer;
            ++votes;
        }
        last = address(0);
        for (uint256 i; i < e.nestedApprovals.length; ++i) {
            NestedSafeApproval calldata approval = e.nestedApprovals[i];
            require(approval.childSafe > last && _isOwner(voters, approval.childSafe, OWNER_SAFE), "fixture nested");
            last = approval.childSafe;
            SafeAuthorityRecord memory child = _voterRecord(positions, approval.childSafe);
            address signer = ECDSA.recover(approval.messageHash, approval.approval.signatures);
            require(_isOwner(child, signer, OWNER_EOA), "wrong nested signer");
            ++votes;
        }
        require(votes >= voters.threshold, "wrong current signer");
    }

    function _requireAuthorityContextIdle(uint256, address) internal view override {
        require(!busy, "application context busy");
    }

    function _isOwner(SafeAuthorityRecord memory r, address owner, uint8 kind) private pure returns (bool) {
        for (uint256 i; i < r.owners.length; ++i) {
            if (r.owners[i].owner == owner) return r.owners[i].kind == kind;
        }
        return false;
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

    /// @dev One ECDSA entry per key, ordered by signer address as the vote mock requires.
    function _sign(SafeTx memory tx_, address safe, uint256 chain, uint256[] memory keys)
        internal
        pure
        returns (SafeTxEvidence memory)
    {
        bytes32 digest = SafeHashes.transactionHash(tx_, safe, chain);
        for (uint256 i = 1; i < keys.length; ++i) {
            for (uint256 j = i; j != 0 && vm.addr(keys[j]) < vm.addr(keys[j - 1]); --j) {
                (keys[j], keys[j - 1]) = (keys[j - 1], keys[j]);
            }
        }
        bytes memory signatures;
        for (uint256 i; i < keys.length; ++i) {
            signatures = bytes.concat(signatures, _ecdsa(keys[i], digest));
        }
        return SafeTxEvidence(SignedSafeTx(tx_, signatures), new NestedSafeApproval[](0));
    }

    function _sign(SafeTx memory tx_, address safe, uint256 chain, uint256 key)
        internal
        pure
        returns (SafeTxEvidence memory)
    {
        return _sign(tx_, safe, chain, _keys(key));
    }

    /// @dev Adds a mock vote by Safe owner `child`, signed by `key` (one of child's owners).
    function _withNested(SafeTxEvidence memory e, address child, uint256 key)
        internal
        pure
        returns (SafeTxEvidence memory)
    {
        bytes32 messageHash = keccak256(abi.encode(e.signedSafeTx.safeTx.data, child));
        SafeTx memory empty;
        e.nestedApprovals = new NestedSafeApproval[](1);
        e.nestedApprovals[0] = NestedSafeApproval(child, messageHash, SignedSafeTx(empty, _ecdsa(key, messageHash)));
        return e;
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

    function _ecdsa(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
