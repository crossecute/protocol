// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeAuthorityState, SafeAuthority} from "src/messaging/signed/SafeAuthority.sol";
import {SafeSignaturesUtils} from "src/messaging/signed/SafeSignaturesUtils.sol";
import {SafeAuthorityRecord, SafeOwner, OWNER_EOA, OWNER_SAFE} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {NestedSafeApproval} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {SafeSigs, Records} from "test/signed/SignedFixtures.sol";

contract AuthorityHarness {
    using SafeAuthority for SafeAuthorityState;

    SafeAuthorityState internal authority;

    /// @notice Expose authority snapshot storage through a test harness.
    /// @dev The verifier tests need a real stored graph without deploying a complete signed
    ///      conduit.
    function store(SafeAuthorityRecord[] memory records, uint256 chainId) external {
        authority.store(records, chainId);
    }

    /// @notice Expose the stored-authority verifier through an external call.
    /// @dev Tests can exercise signature acceptance and exact failures independently of
    ///      transport and payload decoding.
    function verify(bytes32 hash, bytes memory signatures, NestedSafeApproval[] memory approvals) external view {
        authority.verify(hash, signatures, approvals);
    }

    /// @notice Return the harness's canonical stored authority records.
    /// @dev Readback tests need to compare stored owner order with the input snapshot.
    function records() external view returns (SafeAuthorityRecord[] memory) {
        return authority.readRecords();
    }
}

/// @dev Recursive verification against stored authority (#108 Q5, Q6): Safe 1.5.0 entry rules,
///      nested Safes counted once with their own threshold, `v = 1` refused, empty nested
///      signatures backed only by a verified signed approval.
contract SafeAuthorityTest is Test {
    uint256 constant CHAIN = 1;
    address constant ROOT = address(0xA0);
    address constant CHILD = address(0xC1);
    address constant LIB = address(0x5161);
    bytes32 constant H = keccak256("safe tx hash");

    AuthorityHarness h;

    /// @notice Store a root Safe with EOA owners and a nested child Safe.
    /// @dev A shared fixture lets tests vary signature types and evidence while keeping the
    ///      expected owner graph fixed.
    function setUp() public {
        h = new AuthorityHarness();
        SafeOwner[] memory rootOwners = new SafeOwner[](3);
        rootOwners[0] = SafeOwner(CHILD, OWNER_SAFE);
        rootOwners[1] = SafeOwner(vm.addr(1), OWNER_EOA);
        rootOwners[2] = SafeOwner(vm.addr(2), OWNER_EOA);
        h.store(
            Records.list(
                Records.record(ROOT, 2, rootOwners), Records.record(CHILD, 1, Records.eoaOwners(Records.pks(4, 5)))
            ),
            CHAIN
        );
    }

    /// @notice Return an empty nested-approval list.
    /// @dev Tests that rely on inline signatures must not accidentally pass because of separate
    ///      cached evidence.
    function _none() internal pure returns (NestedSafeApproval[] memory) {
        return new NestedSafeApproval[](0);
    }

    /// @notice Compute the child-domain message hash for the test parent hash.
    /// @dev Nested signatures must authorize the same parent message in the child's own Safe
    ///      domain.
    function _childHash() internal pure returns (bytes32) {
        return SafeSignaturesUtils.nestedHash(H, CHILD, CHAIN);
    }

    /// @notice Verify a quorum of direct EOA signatures.
    /// @dev This establishes the basic acceptance path before testing malformed or nested
    ///      evidence.
    function test_twoEoaOwnersVerify() public view {
        h.verify(H, SafeSigs.blob(SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(2)), H), _none());
    }

    /// @notice Verify a quorum mixing direct and Ethereum-prefixed EOA signatures.
    /// @dev Both Safe-supported ECDSA formats must work together in one ordered blob.
    function test_mixedPrefixedAndDirectSignaturesVerify() public view {
        h.verify(H, SafeSigs.blob(SafeSigs.two(SafeSigs.prefixed(1), SafeSigs.eoa(2)), H), _none());
    }

    /// @notice Read the stored authority back and compare its owner order.
    /// @dev Canonical hashing depends on source Safe order, not sorted signer order.
    function test_theReadbackPreservesOwnerOrder() public view {
        SafeAuthorityRecord[] memory records = h.records();
        assertEq(records.length, 2);
        assertEq(records[0].owners[0].owner, CHILD);
        assertEq(records[0].owners[1].owner, vm.addr(1));
        assertEq(records[0].owners[2].owner, vm.addr(2));
        assertEq(records[1].safe, CHILD);
    }

    /// @notice Supply fewer signature entries than the root threshold.
    /// @dev An incomplete quorum must fail before missing bytes can be read as signatures.
    function test_oneSignatureShortRefuses() public {
        bytes memory blob = SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(1)), H);
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.SignaturesTooShort.selector, ROOT));
        h.verify(H, blob, _none());
    }

    /// @notice Sign with an EOA absent from the stored owner list.
    /// @dev A valid cryptographic signature is insufficient without owner membership.
    function test_aStrangerRefuses() public {
        bytes memory blob = SafeSigs.blob(SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(9)), H);
        vm.expectRevert(abi.encodeWithSelector(SafeAuthority.NotAnOwner.selector, ROOT, vm.addr(9)));
        h.verify(H, blob, _none());
    }

    /// @notice Submit otherwise valid signers in the wrong order.
    /// @dev Safe-compatible ascending order is part of the verifier's duplicate-prevention
    ///      rule.
    function test_signersOutOfOrderRefuse() public {
        bytes memory a = SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(1)), H);
        bytes memory b = SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(2)), H);
        (bytes memory lo, bytes memory hi) = vm.addr(1) < vm.addr(2) ? (a, b) : (b, a);
        vm.expectRevert(abi.encodeWithSelector(SafeAuthority.SignersNotAscending.selector, ROOT));
        h.verify(H, abi.encodePacked(hi, lo), _none());
    }

    /// @notice Repeat one authorized signer in the blob.
    /// @dev One owner must never count toward the threshold twice.
    function test_theSameSignerTwiceRefuses() public {
        bytes memory a = SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(1)), H);
        vm.expectRevert(abi.encodeWithSelector(SafeAuthority.SignersNotAscending.selector, ROOT));
        h.verify(H, abi.encodePacked(a, a), _none());
    }

    /// @notice Submit a `v = 1` approved-hash entry.
    /// @dev Receiver verification cannot depend on source storage or the source executor's
    ///      identity.
    function test_anApprovedHashEntryRefuses() public {
        bytes memory approved = abi.encodePacked(bytes32(uint256(uint160(vm.addr(1)))), bytes32(0), uint8(1));
        bytes memory blob = abi.encodePacked(approved, SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(2)), H));
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.ApprovedHashUnsupported.selector, ROOT));
        h.verify(H, blob, _none());
    }

    /// @notice Submit an unsupported signature-type byte.
    /// @dev Unknown formats must fail closed rather than being treated as EOA or contract
    ///      evidence.
    function test_anUnknownSignatureTypeRefuses() public {
        bytes memory blob = SafeSigs.blob(SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(2)), H);
        blob[64] = bytes1(uint8(29));
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.InvalidSignatureType.selector, uint8(29)));
        h.verify(H, blob, _none());
    }

    /// @notice Verify an inline child quorum as one owner of the parent Safe.
    /// @dev A nested Safe must satisfy its own threshold without contributing multiple parent
    ///      votes.
    function test_anInlineNestedSignatureCountsOnceWithTheChildsThreshold() public view {
        bytes memory childBlob = SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(4)), _childHash());
        h.verify(H, SafeSigs.blob(SafeSigs.two(SafeSigs.nested(CHILD, childBlob), SafeSigs.eoa(1)), H), _none());
    }

    /// @notice Sign the nested payload over a different hash.
    /// @dev Child signatures must be bound to the exact parent authorization and child domain.
    function test_anInlineNestedSignatureOverTheWrongHashRefuses() public {
        bytes memory childBlob = SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(4)), H);
        bytes memory blob = SafeSigs.blob(SafeSigs.two(SafeSigs.nested(CHILD, childBlob), SafeSigs.eoa(1)), H);
        vm.expectPartialRevert(SafeAuthority.NotAnOwner.selector);
        h.verify(H, blob, _none());
    }

    /// @notice Encode an EOA owner as a nested contract entry.
    /// @dev The claimed signature kind must match the stored owner kind.
    function test_aNestedEntryForAnEoaOwnerRefuses() public {
        bytes memory blob = SafeSigs.blob(SafeSigs.two(SafeSigs.nested(vm.addr(1), hex"00"), SafeSigs.eoa(2)), H);
        vm.expectRevert(abi.encodeWithSelector(SafeAuthority.NotAnOwner.selector, ROOT, vm.addr(1)));
        h.verify(H, blob, _none());
    }

    /// @notice Build a child's signed approval using the selected private key.
    /// @dev Choosing the key lets tests distinguish valid child quorum evidence from signatures
    ///      by strangers.
    function _approvalFor(uint256 pk) internal pure returns (NestedSafeApproval[] memory nestedApprovals) {
        nestedApprovals = new NestedSafeApproval[](1);
        nestedApprovals[0] = SafeSigs.approval(CHILD, H, CHAIN, SafeSigs.one(SafeSigs.eoa(pk)), LIB);
    }

    /// @notice Build a parent signature blob with an empty child payload.
    /// @dev This isolates the path that must obtain and verify separate signed approval
    ///      evidence.
    function _emptyNested() internal pure returns (bytes memory) {
        return SafeSigs.blob(SafeSigs.two(SafeSigs.nested(CHILD, ""), SafeSigs.eoa(1)), H);
    }

    /// @notice Back an empty child payload with a valid signed approval.
    /// @dev The receiver must support source-cached approvals without querying source-chain
    ///      storage.
    function test_anEmptyNestedSignatureCountsWithASignedApproval() public view {
        h.verify(H, _emptyNested(), _approvalFor(5));
    }

    /// @notice Leave an empty nested payload without matching approval evidence.
    /// @dev A claimed child address alone must not count as authorization.
    function test_anEmptyNestedSignatureWithoutAnApprovalRefuses() public {
        vm.expectRevert(abi.encodeWithSelector(SafeAuthority.MissingNestedSafeApproval.selector, CHILD, _childHash()));
        h.verify(H, _emptyNested(), _none());
    }

    /// @notice Back an empty payload with an approval signed by a nonowner.
    /// @dev Cached-looking evidence must still satisfy the child's stored quorum.
    function test_anApprovalSignedByAStrangerRefuses() public {
        vm.expectRevert(abi.encodeWithSelector(SafeAuthority.NotAnOwner.selector, CHILD, vm.addr(8)));
        h.verify(H, _emptyNested(), _approvalFor(8));
    }

    /// @notice Change the message approved by the child transaction.
    /// @dev Approval evidence must match this parent hash, not merely name the correct child.
    function test_anApprovalOfAnotherMessageRefuses() public {
        NestedSafeApproval[] memory nestedApprovals = _approvalFor(5);
        nestedApprovals[0].approval.safeTx.data =
            abi.encodeWithSelector(bytes4(0x85a5affe), abi.encode(keccak256("other")));
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.NotANestedSafeApprovalOf.selector, CHILD, H));
        h.verify(H, _emptyNested(), nestedApprovals);
    }

    /// @notice Change the approval operation from DELEGATECALL to CALL.
    /// @dev Only the supported Safe message-approval transaction shape can back an empty nested
    ///      signature.
    function test_anApprovalAsACallRefuses() public {
        NestedSafeApproval[] memory nestedApprovals = _approvalFor(5);
        nestedApprovals[0].approval.safeTx.operation = 0;
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.NotANestedSafeApprovalOf.selector, CHILD, H));
        h.verify(H, _emptyNested(), nestedApprovals);
    }

    /// @notice Put a `v = 1` entry inside the approval's own signatures.
    /// @dev The source-state-dependent format must be rejected at every nesting depth.
    function test_anApprovalWithAnApprovedHashEntryRefuses() public {
        NestedSafeApproval[] memory nestedApprovals = _approvalFor(5);
        nestedApprovals[0].approval.signatures =
            abi.encodePacked(bytes32(uint256(uint160(vm.addr(5)))), bytes32(0), uint8(1));
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.ApprovedHashUnsupported.selector, CHILD));
        h.verify(H, _emptyNested(), nestedApprovals);
    }

    /// @notice Supply an unused approval, then duplicate the required child/message entry.
    /// @dev Unneeded evidence must not change a quorum result, while duplicate lookup keys must
    ///      be rejected as ambiguous input.
    function test_unusedApprovalsAreIgnoredAndDuplicatesRefuse() public {
        NestedSafeApproval[] memory nestedApprovals = new NestedSafeApproval[](2);
        nestedApprovals[0] = SafeSigs.approval(CHILD, keccak256("unrelated"), CHAIN, SafeSigs.one(SafeSigs.eoa(4)), LIB);
        nestedApprovals[1] = _approvalFor(5)[0];
        h.verify(H, _emptyNested(), nestedApprovals);

        nestedApprovals[0] = nestedApprovals[1];
        vm.expectRevert(abi.encodeWithSelector(SafeAuthority.DuplicateNestedSafeApproval.selector, CHILD, _childHash()));
        h.verify(H, _emptyNested(), nestedApprovals);
    }

    /// @notice Point a nested payload offset into the required fixed signature entries.
    /// @dev Payload extraction must not reinterpret signer headers as child signature bytes.
    function test_aContractSignatureOffsetIntoTheStaticPartRefuses() public {
        bytes memory blob = _emptyNested();
        // Point the nested entry's offset at 0, inside the static part.
        uint256 entry = CHILD < vm.addr(1) ? 0 : 65;
        for (uint256 i; i < 32; ++i) {
            blob[entry + 32 + i] = 0;
        }
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.MalformedContractSignature.selector, ROOT));
        h.verify(H, blob, _approvalFor(5));
    }

    /// @notice Cut bytes from an inline child signature payload.
    /// @dev The advertised payload length must fit the containing blob before recursive
    ///      verification.
    function test_aTruncatedContractSignatureRefuses() public {
        bytes memory childBlob = SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(4)), _childHash());
        bytes memory blob = SafeSigs.blob(SafeSigs.two(SafeSigs.nested(CHILD, childBlob), SafeSigs.eoa(1)), H);
        assembly ("memory-safe") {
            mstore(blob, sub(mload(blob), 1))
        }
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.MalformedContractSignature.selector, ROOT));
        h.verify(H, blob, _none());
    }

    /// @notice Append unused bytes to a complete EOA quorum.
    /// @dev Verification should match Safe's required-entry rule rather than assigning
    ///      authority to trailing data.
    function test_bytesAfterTheThresholdEntriesAreIgnored() public view {
        bytes memory blob = SafeSigs.blob(SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(2)), H);
        h.verify(H, abi.encodePacked(blob, hex"deadbeef"), _none());
    }
}
