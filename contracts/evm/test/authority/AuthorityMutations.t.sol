// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Call} from "src/messaging/Call.sol";
import {MAX_SAFE_OWNERS} from "src/messaging/authority/AuthorityGraph.sol";
import {AuthorityMutations} from "src/messaging/authority/AuthorityMutations.sol";
import {AuthorityUpdateEncoding} from "src/messaging/authority/AuthorityUpdateEncoding.sol";
import {SafeOwner, SafeAuthorityRecord, OWNER_EOA, OWNER_SAFE} from "src/messaging/signed/types/SafeAuthorityTypes.sol";

contract AuthorityMutationsHarness {
    function applyMutations(
        SafeAuthorityRecord memory current,
        Call[] memory mutations,
        SafeAuthorityRecord memory expected
    ) external pure {
        AuthorityMutations.applyMutations(current, mutations, expected);
    }
}

/// @dev Rule-level cases. The differential fuzz against a real Safe 1.5.0 is in the guard suite
///      (AuthorityMutationsSafe.t.sol).
contract AuthorityMutationsTest is Test {
    address internal constant SAFE = address(0x5AFE);
    address internal constant SENTINEL = address(1);
    address internal constant A = address(0xA);
    address internal constant B = address(0xB);
    address internal constant C = address(0xC);
    address internal constant D = address(0xD);

    AuthorityMutationsHarness internal harness;

    function setUp() public {
        harness = new AuthorityMutationsHarness();
    }

    function test_add_insertsAtFrontWithThreshold() public view {
        harness.applyMutations(_eoas(_list(A, B), 1), _one(_add(C, 2)), _eoas(_list3(C, A, B), 2));
    }

    function test_remove_firstAndMiddle() public view {
        harness.applyMutations(_eoas(_list3(A, B, C), 2), _one(_remove(SENTINEL, A, 2)), _eoas(_list(B, C), 2));
        harness.applyMutations(_eoas(_list3(A, B, C), 2), _one(_remove(A, B, 1)), _eoas(_list(A, C), 1));
    }

    function test_swap_keepsPlace() public view {
        harness.applyMutations(_eoas(_list3(A, B, C), 2), _one(_swap(A, B, D)), _eoas(_list3(A, D, C), 2));
    }

    function test_changeThreshold() public view {
        harness.applyMutations(_eoas(_list(A, B), 1), _one(_change(2)), _eoas(_list(A, B), 2));
    }

    /// @dev T12: the threshold rises midway and the final record is checked against the last step.
    function test_batch_thresholdChangesMidway() public view {
        Call[] memory batch = new Call[](3);
        batch[0] = _add(B, 2);
        batch[1] = _swap(B, A, C);
        batch[2] = _add(D, 3);
        harness.applyMutations(_eoas(_one(A), 1), batch, _eoas(_list3(D, B, C), 3));
    }

    function test_rejects_invalidNewOwner() public {
        _expectRevert(
            _eoas(_one(A), 1),
            _one(_add(address(0), 1)),
            abi.encodeWithSelector(AuthorityMutations.MutationOwner.selector, 0, address(0))
        );
        _expectRevert(
            _eoas(_one(A), 1),
            _one(_add(SENTINEL, 1)),
            abi.encodeWithSelector(AuthorityMutations.MutationOwner.selector, 0, SENTINEL)
        );
        _expectRevert(
            _eoas(_one(A), 1),
            _one(_add(SAFE, 1)),
            abi.encodeWithSelector(AuthorityMutations.MutationOwner.selector, 0, SAFE)
        );
        _expectRevert(
            _eoas(_one(A), 1), _one(_add(A, 1)), abi.encodeWithSelector(AuthorityMutations.MutationOwner.selector, 0, A)
        );
        _expectRevert(
            _eoas(_list(A, B), 1),
            _one(_swap(SENTINEL, A, B)),
            abi.encodeWithSelector(AuthorityMutations.MutationOwner.selector, 0, B)
        );
    }

    function test_rejects_wrongPredecessor() public {
        SafeAuthorityRecord memory current = _eoas(_list3(A, B, C), 1);
        _expectRevert(
            current,
            _one(_remove(SENTINEL, B, 1)),
            abi.encodeWithSelector(AuthorityMutations.MutationPredecessor.selector, 0, SENTINEL, B)
        );
        _expectRevert(
            current,
            _one(_remove(C, A, 1)),
            abi.encodeWithSelector(AuthorityMutations.MutationPredecessor.selector, 0, C, A)
        );
        _expectRevert(
            current,
            _one(_remove(C, D, 1)),
            abi.encodeWithSelector(AuthorityMutations.MutationPredecessor.selector, 0, C, D)
        );
        _expectRevert(
            current,
            _one(_remove(C, SENTINEL, 1)),
            abi.encodeWithSelector(AuthorityMutations.MutationPredecessor.selector, 0, C, SENTINEL)
        );
        _expectRevert(
            current,
            _one(_swap(B, B, D)),
            abi.encodeWithSelector(AuthorityMutations.MutationPredecessor.selector, 0, B, B)
        );
    }

    function test_rejects_invalidThreshold() public {
        _expectRevert(
            _eoas(_list(A, B), 1),
            _one(_change(0)),
            abi.encodeWithSelector(AuthorityMutations.MutationThreshold.selector, 0, 0, 2)
        );
        _expectRevert(
            _eoas(_list(A, B), 1),
            _one(_change(3)),
            abi.encodeWithSelector(AuthorityMutations.MutationThreshold.selector, 0, 3, 2)
        );
        _expectRevert(
            _eoas(_list(A, B), 1),
            _one(_add(C, 4)),
            abi.encodeWithSelector(AuthorityMutations.MutationThreshold.selector, 0, 4, 3)
        );
        _expectRevert(
            _eoas(_list(A, B), 2),
            _one(_remove(SENTINEL, A, 2)),
            abi.encodeWithSelector(AuthorityMutations.MutationThreshold.selector, 0, 2, 1)
        );
        // The last owner cannot be removed.
        _expectRevert(
            _eoas(_one(A), 1),
            _one(_remove(SENTINEL, A, 1)),
            abi.encodeWithSelector(AuthorityMutations.MutationThreshold.selector, 0, 1, 0)
        );
    }

    /// @dev Each step is checked, not only the final record: raising the threshold before the
    ///      owner that makes it reachable rejects even though the end state is valid.
    function test_rejects_invalidIntermediateStep() public {
        Call[] memory batch = new Call[](2);
        batch[0] = _change(2);
        batch[1] = _add(B, 2);
        _expectRevert(
            _eoas(_one(A), 1), batch, abi.encodeWithSelector(AuthorityMutations.MutationThreshold.selector, 0, 2, 1)
        );
    }

    /// @dev T18: 16 owners pass; a 17th rejects even when a later step removes one.
    function test_ownerCap() public {
        address[] memory sixteen = _owners(MAX_SAFE_OWNERS);
        address[] memory fifteen = _owners(MAX_SAFE_OWNERS - 1);
        address added = address(uint160(0x1000 + MAX_SAFE_OWNERS));
        address[] memory expected = new address[](MAX_SAFE_OWNERS);
        expected[0] = added;
        for (uint256 i; i < fifteen.length; ++i) {
            expected[i + 1] = fifteen[i];
        }
        harness.applyMutations(_eoas(fifteen, 1), _one(_add(added, 1)), _eoas(expected, 1));

        Call[] memory batch = new Call[](2);
        batch[0] = _add(added, 1);
        batch[1] = _remove(added, sixteen[0], 1);
        _expectRevert(_eoas(sixteen, 1), batch, abi.encodeWithSelector(AuthorityMutations.TooManyOwners.selector, 0));
    }

    function test_rejects_unsupportedCall() public {
        bytes memory invalid = abi.encodeWithSelector(AuthorityUpdateEncoding.InvalidMutation.selector, 0);
        Call memory wrongTarget = _add(B, 1);
        wrongTarget.target = A;
        _expectRevert(_eoas(_one(A), 1), _one(wrongTarget), invalid);
        Call memory withValue = _add(B, 1);
        withValue.value = 1;
        _expectRevert(_eoas(_one(A), 1), _one(withValue), invalid);
        _expectRevert(_eoas(_one(A), 1), _one(Call(SAFE, 0, abi.encodeWithSignature("setGuard(address)", B))), invalid);
        _expectRevert(_eoas(_one(A), 1), _one(Call(SAFE, 0, hex"0d58")), invalid);
    }

    function test_rejects_resultMismatch() public {
        bytes memory mismatch = abi.encodeWithSelector(AuthorityMutations.MutationResultMismatch.selector);
        // Wrong order: Safe inserts at the front.
        _expectRevert(_eoas(_one(A), 1), _one(_add(B, 1)), _eoas(_list(A, B), 1), mismatch);
        // Wrong threshold, wrong Safe.
        _expectRevert(_eoas(_one(A), 1), _one(_add(B, 1)), _eoas(_list(B, A), 2), mismatch);
        SafeAuthorityRecord memory otherSafe = _eoas(_list(B, A), 1);
        otherSafe.safe = address(0xBEEF);
        _expectRevert(_eoas(_one(A), 1), _one(_add(B, 1)), otherSafe, mismatch);
    }

    /// @dev An added owner takes its kind from the expected record; a kept owner cannot change kind.
    function test_kinds() public {
        SafeAuthorityRecord memory current = _eoas(_list(A, B), 1);
        SafeAuthorityRecord memory expected = _eoas(_list3(C, A, B), 1);
        expected.owners[0].kind = OWNER_SAFE;
        harness.applyMutations(current, _one(_add(C, 1)), expected);

        expected.owners[1].kind = OWNER_SAFE;
        _expectRevert(
            current,
            _one(_add(C, 1)),
            expected,
            abi.encodeWithSelector(AuthorityMutations.MutationResultMismatch.selector)
        );

        // Removing and re-adding A in one batch takes A's kind from the expected record.
        Call[] memory batch = new Call[](2);
        batch[0] = _remove(SENTINEL, A, 1);
        batch[1] = _add(A, 1);
        SafeAuthorityRecord memory readded = _eoas(_list(A, B), 1);
        readded.owners[0].kind = OWNER_SAFE;
        harness.applyMutations(current, batch, readded);
    }

    /* ---------------------------------- helpers --------------------------------- */

    function _expectRevert(SafeAuthorityRecord memory current, Call[] memory mutations, bytes memory reason) internal {
        _expectRevert(current, mutations, current, reason);
    }

    function _expectRevert(
        SafeAuthorityRecord memory current,
        Call[] memory mutations,
        SafeAuthorityRecord memory expected,
        bytes memory reason
    ) internal {
        vm.expectRevert(reason);
        harness.applyMutations(current, mutations, expected);
    }

    function _eoas(address[] memory owners, uint256 threshold) internal pure returns (SafeAuthorityRecord memory r) {
        r.safe = SAFE;
        r.threshold = threshold;
        r.owners = new SafeOwner[](owners.length);
        for (uint256 i; i < owners.length; ++i) {
            r.owners[i] = SafeOwner(owners[i], OWNER_EOA);
        }
    }

    function _owners(uint256 n) internal pure returns (address[] memory list) {
        list = new address[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = address(uint160(0x1000 + i));
        }
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _list(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        (list[0], list[1]) = (a, b);
    }

    function _list3(address a, address b, address c) internal pure returns (address[] memory list) {
        list = new address[](3);
        (list[0], list[1], list[2]) = (a, b, c);
    }

    function _one(Call memory c) internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = c;
    }

    function _add(address owner, uint256 threshold) internal pure returns (Call memory) {
        return Call(SAFE, 0, abi.encodeWithSelector(AuthorityUpdateEncoding.ADD_OWNER, owner, threshold));
    }

    function _remove(address prev, address owner, uint256 threshold) internal pure returns (Call memory) {
        return Call(SAFE, 0, abi.encodeWithSelector(AuthorityUpdateEncoding.REMOVE_OWNER, prev, owner, threshold));
    }

    function _swap(address prev, address oldOwner, address newOwner) internal pure returns (Call memory) {
        return Call(SAFE, 0, abi.encodeWithSelector(AuthorityUpdateEncoding.SWAP_OWNER, prev, oldOwner, newOwner));
    }

    function _change(uint256 threshold) internal pure returns (Call memory) {
        return Call(SAFE, 0, abi.encodeWithSelector(AuthorityUpdateEncoding.CHANGE_THRESHOLD, threshold));
    }
}
