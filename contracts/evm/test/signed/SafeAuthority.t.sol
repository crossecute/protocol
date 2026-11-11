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

    function store(SafeAuthorityRecord[] memory records, uint256 chainId) external {
        authority.store(records, chainId);
    }

    function verify(bytes32 hash, bytes memory signatures, NestedSafeApproval[] memory approvals) external view {
        authority.verify(hash, signatures, approvals);
    }

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

    /// ROOT 2-of-3: CHILD (1-of-2 over keys 4, 5), key 1, key 2.
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

    function _none() internal pure returns (NestedSafeApproval[] memory) {
        return new NestedSafeApproval[](0);
    }

    function _childHash() internal pure returns (bytes32) {
        return SafeSignaturesUtils.nestedHash(H, CHILD, CHAIN);
    }

    function test_twoEoaOwnersVerify() public view {
        h.verify(H, SafeSigs.blob(SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(2)), H), _none());
    }

    function test_mixedPrefixedAndDirectSignaturesVerify() public view {
        h.verify(H, SafeSigs.blob(SafeSigs.two(SafeSigs.prefixed(1), SafeSigs.eoa(2)), H), _none());
    }

    function test_theReadbackPreservesOwnerOrder() public view {
        SafeAuthorityRecord[] memory records = h.records();
        assertEq(records.length, 2);
        assertEq(records[0].owners[0].owner, CHILD);
        assertEq(records[0].owners[1].owner, vm.addr(1));
        assertEq(records[0].owners[2].owner, vm.addr(2));
        assertEq(records[1].safe, CHILD);
    }

    function test_oneSignatureShortRefuses() public {
        bytes memory blob = SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(1)), H);
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.SignaturesTooShort.selector, ROOT));
        h.verify(H, blob, _none());
    }

    function test_aStrangerRefuses() public {
        bytes memory blob = SafeSigs.blob(SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(9)), H);
        vm.expectRevert(abi.encodeWithSelector(SafeAuthority.NotAnOwner.selector, ROOT, vm.addr(9)));
        h.verify(H, blob, _none());
    }

    function test_signersOutOfOrderRefuse() public {
        bytes memory a = SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(1)), H);
        bytes memory b = SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(2)), H);
        (bytes memory lo, bytes memory hi) = vm.addr(1) < vm.addr(2) ? (a, b) : (b, a);
        vm.expectRevert(abi.encodeWithSelector(SafeAuthority.SignersNotAscending.selector, ROOT));
        h.verify(H, abi.encodePacked(hi, lo), _none());
    }

    function test_theSameSignerTwiceRefuses() public {
        bytes memory a = SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(1)), H);
        vm.expectRevert(abi.encodeWithSelector(SafeAuthority.SignersNotAscending.selector, ROOT));
        h.verify(H, abi.encodePacked(a, a), _none());
    }

    function test_anApprovedHashEntryRefuses() public {
        bytes memory approved = abi.encodePacked(bytes32(uint256(uint160(vm.addr(1)))), bytes32(0), uint8(1));
        bytes memory blob = abi.encodePacked(approved, SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(2)), H));
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.ApprovedHashUnsupported.selector, ROOT));
        h.verify(H, blob, _none());
    }

    function test_anUnknownSignatureTypeRefuses() public {
        bytes memory blob = SafeSigs.blob(SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(2)), H);
        blob[64] = bytes1(uint8(29));
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.InvalidSignatureType.selector, uint8(29)));
        h.verify(H, blob, _none());
    }

    function test_anInlineNestedSignatureCountsOnceWithTheChildsThreshold() public view {
        bytes memory childBlob = SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(4)), _childHash());
        h.verify(H, SafeSigs.blob(SafeSigs.two(SafeSigs.nested(CHILD, childBlob), SafeSigs.eoa(1)), H), _none());
    }

    function test_anInlineNestedSignatureOverTheWrongHashRefuses() public {
        bytes memory childBlob = SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(4)), H);
        bytes memory blob = SafeSigs.blob(SafeSigs.two(SafeSigs.nested(CHILD, childBlob), SafeSigs.eoa(1)), H);
        vm.expectPartialRevert(SafeAuthority.NotAnOwner.selector);
        h.verify(H, blob, _none());
    }

    function test_aNestedEntryForAnEoaOwnerRefuses() public {
        bytes memory blob = SafeSigs.blob(SafeSigs.two(SafeSigs.nested(vm.addr(1), hex"00"), SafeSigs.eoa(2)), H);
        vm.expectRevert(abi.encodeWithSelector(SafeAuthority.NotAnOwner.selector, ROOT, vm.addr(1)));
        h.verify(H, blob, _none());
    }

    function _approvalFor(uint256 pk) internal pure returns (NestedSafeApproval[] memory nestedApprovals) {
        nestedApprovals = new NestedSafeApproval[](1);
        nestedApprovals[0] = SafeSigs.approval(CHILD, H, CHAIN, SafeSigs.one(SafeSigs.eoa(pk)), LIB);
    }

    function _emptyNested() internal pure returns (bytes memory) {
        return SafeSigs.blob(SafeSigs.two(SafeSigs.nested(CHILD, ""), SafeSigs.eoa(1)), H);
    }

    function test_anEmptyNestedSignatureCountsWithASignedApproval() public view {
        h.verify(H, _emptyNested(), _approvalFor(5));
    }

    function test_anEmptyNestedSignatureWithoutAnApprovalRefuses() public {
        vm.expectRevert(abi.encodeWithSelector(SafeAuthority.MissingNestedSafeApproval.selector, CHILD, _childHash()));
        h.verify(H, _emptyNested(), _none());
    }

    function test_anApprovalSignedByAStrangerRefuses() public {
        vm.expectRevert(abi.encodeWithSelector(SafeAuthority.NotAnOwner.selector, CHILD, vm.addr(8)));
        h.verify(H, _emptyNested(), _approvalFor(8));
    }

    function test_anApprovalOfAnotherMessageRefuses() public {
        NestedSafeApproval[] memory nestedApprovals = _approvalFor(5);
        nestedApprovals[0].approval.safeTx.data =
            abi.encodeWithSelector(bytes4(0x85a5affe), abi.encode(keccak256("other")));
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.NotANestedSafeApprovalOf.selector, CHILD, H));
        h.verify(H, _emptyNested(), nestedApprovals);
    }

    function test_anApprovalAsACallRefuses() public {
        NestedSafeApproval[] memory nestedApprovals = _approvalFor(5);
        nestedApprovals[0].approval.safeTx.operation = 0;
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.NotANestedSafeApprovalOf.selector, CHILD, H));
        h.verify(H, _emptyNested(), nestedApprovals);
    }

    function test_anApprovalWithAnApprovedHashEntryRefuses() public {
        NestedSafeApproval[] memory nestedApprovals = _approvalFor(5);
        nestedApprovals[0].approval.signatures =
            abi.encodePacked(bytes32(uint256(uint160(vm.addr(5)))), bytes32(0), uint8(1));
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.ApprovedHashUnsupported.selector, CHILD));
        h.verify(H, _emptyNested(), nestedApprovals);
    }

    function test_unusedApprovalsAreIgnoredAndDuplicatesRefuse() public {
        NestedSafeApproval[] memory nestedApprovals = new NestedSafeApproval[](2);
        nestedApprovals[0] = SafeSigs.approval(CHILD, keccak256("unrelated"), CHAIN, SafeSigs.one(SafeSigs.eoa(4)), LIB);
        nestedApprovals[1] = _approvalFor(5)[0];
        h.verify(H, _emptyNested(), nestedApprovals);

        nestedApprovals[0] = nestedApprovals[1];
        vm.expectRevert(abi.encodeWithSelector(SafeAuthority.DuplicateNestedSafeApproval.selector, CHILD, _childHash()));
        h.verify(H, _emptyNested(), nestedApprovals);
    }

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

    function test_aTruncatedContractSignatureRefuses() public {
        bytes memory childBlob = SafeSigs.blob(SafeSigs.one(SafeSigs.eoa(4)), _childHash());
        bytes memory blob = SafeSigs.blob(SafeSigs.two(SafeSigs.nested(CHILD, childBlob), SafeSigs.eoa(1)), H);
        assembly ("memory-safe") {
            mstore(blob, sub(mload(blob), 1))
        }
        vm.expectRevert(abi.encodeWithSelector(SafeSignaturesUtils.MalformedContractSignature.selector, ROOT));
        h.verify(H, blob, _none());
    }

    function test_bytesAfterTheThresholdEntriesAreIgnored() public view {
        bytes memory blob = SafeSigs.blob(SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(2)), H);
        h.verify(H, abi.encodePacked(blob, hex"deadbeef"), _none());
    }
}
