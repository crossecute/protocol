// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeSignaturesUtils} from "src/messaging/signed/SafeSignaturesUtils.sol";
import {NestedSafeApproval} from "src/messaging/signed/types/SignedDispatchTypes.sol";

contract SafeSignaturesUtilsHarness {
    function contractOwner(bytes32 r) external pure returns (address) {
        return SafeSignaturesUtils.contractOwner(r);
    }

    function indexOfApproval(NestedSafeApproval[] memory approvals, address child, bytes32 messageHash)
        external
        pure
        returns (uint256)
    {
        return SafeSignaturesUtils.indexOfApproval(approvals, child, messageHash);
    }
}

contract SafeSignaturesUtilsTest is Test {
    SafeSignaturesUtilsHarness internal h = new SafeSignaturesUtilsHarness();
    address internal constant CHILD = address(0xC1);

    function _approvals() internal pure returns (NestedSafeApproval[] memory a) {
        a = new NestedSafeApproval[](2);
        a[0].childSafe = address(0xC1);
        a[0].messageHash = bytes32(uint256(1));
        a[1].childSafe = address(0xC1);
        a[1].messageHash = bytes32(uint256(2));
    }

    /// @notice The lookup keys on child and message hash together.
    function test_indexOfApprovalMatchesTheChildAndTheMessageHashTogether() public view {
        NestedSafeApproval[] memory a = _approvals();
        assertEq(h.indexOfApproval(a, CHILD, bytes32(uint256(1))), 0);
        assertEq(h.indexOfApproval(a, CHILD, bytes32(uint256(2))), 1);
        assertEq(h.indexOfApproval(a, address(0xC2), bytes32(uint256(1))), 2, "another child");
        assertEq(h.indexOfApproval(a, CHILD, bytes32(uint256(3))), 2, "another hash");
        assertEq(h.indexOfApproval(new NestedSafeApproval[](0), CHILD, bytes32(uint256(1))), 0);
    }

    /// @notice The child is the low 160 bits of `r`.
    function test_contractOwnerReadsTheLow160BitsOfR() public view {
        assertEq(h.contractOwner(bytes32(uint256(uint160(CHILD)))), CHILD);
        assertEq(h.contractOwner(bytes32(type(uint256).max)), address(type(uint160).max));
    }
}
