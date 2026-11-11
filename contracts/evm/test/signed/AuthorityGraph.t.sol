// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AuthorityGraph} from "src/messaging/signed/AuthorityGraph.sol";
import {SafeRecord, OwnerEntry, OWNER_EOA, OWNER_SAFE} from "src/messaging/signed/ISignedDispatch.sol";
import {StubSafe} from "test/signed/StubSafe.sol";
import {Records} from "test/signed/SignedFixtures.sol";

contract GraphHarness {
    function derive(address root) external view returns (SafeRecord[] memory) {
        return AuthorityGraph.derive(root);
    }

    function requireCanonical(SafeRecord[] memory records) external view {
        AuthorityGraph.requireCanonical(records);
    }

    function hash(SafeRecord[] memory records) external pure returns (bytes32) {
        return AuthorityGraph.hash(records);
    }
}

/// @dev Canonical derivation and validation of the creation graph (#108 "Owner and nested-Safe
///      composition"): depth first from the root in `getOwners()` order, one record per Safe.
contract AuthorityGraphTest is Test {
    GraphHarness h = new GraphHarness();
    address a1 = vm.addr(1);
    address a2 = vm.addr(2);
    address a3 = vm.addr(3);

    function _safe(address[] memory owners, uint256 threshold) internal returns (StubSafe s) {
        s = new StubSafe();
        s.setOwners(owners, threshold);
    }

    function _addrs(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        (r[0], r[1]) = (a, b);
    }

    function _addrs(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function test_derivesAnEoaOnlySafeInOwnerOrder() public {
        StubSafe root = _safe(_addrs(a3, a1, a2), 2);
        SafeRecord[] memory r = h.derive(address(root));
        assertEq(r.length, 1);
        assertEq(r[0].safe, address(root));
        assertEq(r[0].threshold, 2);
        assertEq(r[0].owners[0].owner, a3);
        assertEq(r[0].owners[1].owner, a1);
        assertEq(r[0].owners[0].kind, OWNER_EOA);
        h.requireCanonical(r);
    }

    function test_derivesNestedAndSharedChildrenDepthFirstWithOneRecordEach() public {
        StubSafe shared = _safe(_addrs(a1, a2), 1);
        StubSafe left = _safe(_addrs(address(shared), a3), 2);
        StubSafe root = _safe(_addrs(address(left), address(shared), a1), 2);
        SafeRecord[] memory r = h.derive(address(root));
        assertEq(r.length, 3);
        assertEq(r[0].safe, address(root));
        assertEq(r[1].safe, address(left));
        assertEq(r[2].safe, address(shared));
        assertEq(r[0].owners[0].kind, OWNER_SAFE);
        assertEq(r[0].owners[1].kind, OWNER_SAFE);
        assertEq(r[0].owners[2].kind, OWNER_EOA);
        h.requireCanonical(r);
    }

    function test_anEip7702DelegatedOwnerIsAnEoa() public {
        address delegated = vm.addr(9);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(0x1234)));
        StubSafe root = _safe(_addrs(delegated, a1), 1);
        assertEq(h.derive(address(root))[0].owners[0].kind, OWNER_EOA);
    }

    function test_anOwnerWithCodeThatIsNotASafeRefuses() public {
        address notSafe = address(new GraphHarness());
        StubSafe root = _safe(_addrs(notSafe, a1), 1);
        vm.expectRevert(abi.encodeWithSelector(AuthorityGraph.NotASafe.selector, notSafe));
        h.derive(address(root));
    }

    function test_aCycleRefuses() public {
        StubSafe x = _safe(_addrs(a1, a2), 1);
        StubSafe y = _safe(_addrs(address(x), a1), 1);
        x.setOwners(_addrs(address(y), a1), 1);
        vm.expectRevert(abi.encodeWithSelector(AuthorityGraph.OwnerCycle.selector, address(x)));
        h.derive(address(x));
    }

    function test_invalidThresholdsAndOwnersRefuse() public {
        StubSafe zero = _safe(_addrs(a1, a2), 0);
        vm.expectRevert(abi.encodeWithSelector(AuthorityGraph.InvalidThreshold.selector, address(zero), 0, 2));
        h.derive(address(zero));

        StubSafe dup = _safe(_addrs(a1, a1), 1);
        vm.expectRevert(abi.encodeWithSelector(AuthorityGraph.InvalidOwner.selector, address(dup), a1));
        h.derive(address(dup));
    }

    function _two() internal view returns (SafeRecord[] memory r) {
        OwnerEntry[] memory rootOwners = new OwnerEntry[](2);
        rootOwners[0] = OwnerEntry(address(0xC1), OWNER_SAFE);
        rootOwners[1] = OwnerEntry(a1, OWNER_EOA);
        r = Records.list(
            Records.record(address(0xA0), 1, rootOwners),
            Records.record(address(0xC1), 1, Records.eoaOwners(Records.pks(2, 3)))
        );
    }

    function test_aMissingChildRecordRefusesEvenWithAnotherRecordPresent() public {
        SafeRecord[] memory r = _two();
        r[1].safe = address(0xC2);
        vm.expectRevert(abi.encodeWithSelector(AuthorityGraph.MissingRecord.selector, address(0xC1)));
        h.requireCanonical(r);
    }

    function test_aDuplicateOrUnreachableRecordRefuses() public {
        SafeRecord[] memory two = _two();
        SafeRecord[] memory dup = Records.list(two[0], two[1], two[1]);
        vm.expectRevert(AuthorityGraph.NotCanonical.selector);
        h.requireCanonical(dup);

        SafeRecord memory stray = Records.record(address(0xD1), 1, Records.eoaOwners(Records.pks(4, 5)));
        vm.expectRevert(AuthorityGraph.NotCanonical.selector);
        h.requireCanonical(Records.list(two[0], two[1], stray));
    }

    function test_anEoaKindOwnerWithARecordRefuses() public {
        SafeRecord[] memory r = _two();
        r[0].owners[0].kind = OWNER_EOA;
        vm.expectRevert(abi.encodeWithSelector(AuthorityGraph.NotCanonical.selector));
        h.requireCanonical(r);
    }

    function test_anUnknownKindRefuses() public {
        SafeRecord[] memory r = _two();
        r[0].owners[1].kind = 2;
        vm.expectRevert(abi.encodeWithSelector(AuthorityGraph.InvalidOwnerKind.selector, address(0xA0), a1));
        h.requireCanonical(r);
    }

    function test_kindOrderAndThresholdEachChangeTheHash() public view {
        SafeRecord[] memory r = _two();
        bytes32 base = h.hash(r);

        SafeRecord[] memory permuted = _two();
        (permuted[1].owners[0], permuted[1].owners[1]) = (permuted[1].owners[1], permuted[1].owners[0]);
        assertTrue(h.hash(permuted) != base);

        SafeRecord[] memory threshold = _two();
        threshold[1].threshold = 2;
        assertTrue(h.hash(threshold) != base);

        SafeRecord[] memory kind = _two();
        kind[0].owners[1].kind = OWNER_SAFE;
        assertTrue(h.hash(kind) != base);

        assertEq(base, keccak256(abi.encode(r)));
    }
}
