// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeAuthorityGraph} from "src/messaging/signed/SafeAuthorityGraph.sol";
import {SafeAuthorityRecord, SafeOwner, OWNER_EOA, OWNER_SAFE} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {StubSafe} from "test/signed/StubSafe.sol";
import {Records} from "test/signed/SignedFixtures.sol";

contract GraphHarness {
    /// @notice Expose live Safe graph derivation through a harness.
    /// @dev Graph tests need to inspect canonical records without creating conduits.
    function derive(address root) external view returns (SafeAuthorityRecord[] memory) {
        return SafeAuthorityGraph.derive(root);
    }

    /// @notice Expose validation of supplied graph records.
    /// @dev An external harness lets tests assert rejection of malformed or ambiguous authority
    ///      snapshots.
    function requireCanonical(SafeAuthorityRecord[] memory records) external view {
        SafeAuthorityGraph.requireCanonical(records);
    }

    /// @notice Expose the encoded graph commitment.
    /// @dev Tests can check that ownership changes move the hash used in signed address
    ///      derivation.
    function hash(SafeAuthorityRecord[] memory records) external pure returns (bytes32) {
        return SafeAuthorityGraph.hash(records);
    }
}

/// @dev Canonical derivation and validation of the creation graph (#108 "Owner and nested-Safe
///      composition"): depth first from the root in `getOwners()` order, one record per Safe.
contract SafeAuthorityGraphTest is Test {
    GraphHarness h = new GraphHarness();
    address a1 = vm.addr(1);
    address a2 = vm.addr(2);
    address a3 = vm.addr(3);

    /// @notice Deploy a stub Safe with the requested owners and threshold.
    /// @dev Controllable nodes let tests build nested, shared and cyclic ownership graphs.
    function _safe(address[] memory owners, uint256 threshold) internal returns (StubSafe s) {
        s = new StubSafe();
        s.setOwners(owners, threshold);
    }

    /// @notice Build a two-address owner list in the supplied order.
    /// @dev Tests need to preserve deliberate source owner order rather than sorting the
    ///      fixture.
    function _addrs(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        (r[0], r[1]) = (a, b);
    }

    /// @notice Build a three-address owner list in the supplied order.
    /// @dev This keeps larger graph fixtures explicit while exercising the same order-sensitive
    ///      encoding.
    function _addrs(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    /// @notice Derive an EOA-only Safe and compare its recorded owners.
    /// @dev The authority snapshot must retain `getOwners()` order for deterministic hashing.
    function test_derivesAnEoaOnlySafeInOwnerOrder() public {
        StubSafe root = _safe(_addrs(a3, a1, a2), 2);
        SafeAuthorityRecord[] memory records = h.derive(address(root));
        assertEq(records.length, 1);
        assertEq(records[0].safe, address(root));
        assertEq(records[0].threshold, 2);
        assertEq(records[0].owners[0].owner, a3);
        assertEq(records[0].owners[1].owner, a1);
        assertEq(records[0].owners[0].kind, OWNER_EOA);
        h.requireCanonical(records);
    }

    /// @notice Derive a graph where nested parents share a child.
    /// @dev Canonical traversal must visit depth first and record a shared Safe only once.
    function test_derivesNestedAndSharedChildrenDepthFirstWithOneRecordEach() public {
        StubSafe shared = _safe(_addrs(a1, a2), 1);
        StubSafe left = _safe(_addrs(address(shared), a3), 2);
        StubSafe root = _safe(_addrs(address(left), address(shared), a1), 2);
        SafeAuthorityRecord[] memory records = h.derive(address(root));
        assertEq(records.length, 3);
        assertEq(records[0].safe, address(root));
        assertEq(records[1].safe, address(left));
        assertEq(records[2].safe, address(shared));
        assertEq(records[0].owners[0].kind, OWNER_SAFE);
        assertEq(records[0].owners[1].kind, OWNER_SAFE);
        assertEq(records[0].owners[2].kind, OWNER_EOA);
        h.requireCanonical(records);
    }

    /// @notice Give an owner an EIP-7702 delegation indicator and derive its graph.
    /// @dev Delegated EOAs must retain EOA signature semantics rather than being queried as
    ///      nested Safes.
    function test_anEip7702DelegatedOwnerIsAnEoa() public {
        address delegated = vm.addr(9);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(0x1234)));
        StubSafe root = _safe(_addrs(delegated, a1), 1);
        assertEq(h.derive(address(root))[0].owners[0].kind, OWNER_EOA);
    }

    /// @notice Insert a contract owner that does not answer Safe ownership queries.
    /// @dev The supported graph must not silently accept arbitrary contract signature
    ///      semantics.
    function test_anOwnerWithCodeThatIsNotASafeRefuses() public {
        address notSafe = address(new GraphHarness());
        StubSafe root = _safe(_addrs(notSafe, a1), 1);
        vm.expectRevert(abi.encodeWithSelector(SafeAuthorityGraph.NotASafe.selector, notSafe));
        h.derive(address(root));
    }

    /// @notice Construct a cycle between nested Safe owners.
    /// @dev Rejecting cyclic authority prevents unbounded traversal and circular quorum
    ///      definitions.
    function test_aCycleRefuses() public {
        StubSafe x = _safe(_addrs(a1, a2), 1);
        StubSafe y = _safe(_addrs(address(x), a1), 1);
        x.setOwners(_addrs(address(y), a1), 1);
        vm.expectRevert(abi.encodeWithSelector(SafeAuthorityGraph.OwnerCycle.selector, address(x)));
        h.derive(address(x));
    }

    /// @notice Try invalid quorums and reserved or duplicate owner addresses.
    /// @dev Malformed authority must be rejected before it can determine conduit addresses or
    ///      stored verification state.
    function test_invalidThresholdsAndOwnersRefuse() public {
        StubSafe zero = _safe(_addrs(a1, a2), 0);
        vm.expectRevert(abi.encodeWithSelector(SafeAuthorityGraph.InvalidThreshold.selector, address(zero), 0, 2));
        h.derive(address(zero));

        StubSafe dup = _safe(_addrs(a1, a1), 1);
        vm.expectRevert(abi.encodeWithSelector(SafeAuthorityGraph.InvalidOwner.selector, address(dup), a1));
        h.derive(address(dup));
    }

    /// @notice Build a canonical two-Safe record graph.
    /// @dev Tests can corrupt one field at a time while starting from valid reachability and
    ///      order.
    function _two() internal view returns (SafeAuthorityRecord[] memory records) {
        SafeOwner[] memory rootOwners = new SafeOwner[](2);
        rootOwners[0] = SafeOwner(address(0xC1), OWNER_SAFE);
        rootOwners[1] = SafeOwner(a1, OWNER_EOA);
        records = Records.list(
            Records.record(address(0xA0), 1, rootOwners),
            Records.record(address(0xC1), 1, Records.eoaOwners(Records.pks(2, 3)))
        );
    }

    /// @notice Omit a required child record while retaining a different record.
    /// @dev The validator must resolve children by address, not assume any extra record
    ///      satisfies the reference.
    function test_aMissingChildRecordRefusesEvenWithAnotherRecordPresent() public {
        SafeAuthorityRecord[] memory records = _two();
        records[1].safe = address(0xC2);
        vm.expectRevert(abi.encodeWithSelector(SafeAuthorityGraph.MissingAuthorityRecord.selector, address(0xC1)));
        h.requireCanonical(records);
    }

    /// @notice Add repeated or disconnected records to a supplied graph.
    /// @dev A canonical commitment must contain exactly one record per reachable Safe.
    function test_aDuplicateOrUnreachableRecordRefuses() public {
        SafeAuthorityRecord[] memory twoRecords = _two();
        SafeAuthorityRecord[] memory duplicateRecords = Records.list(twoRecords[0], twoRecords[1], twoRecords[1]);
        vm.expectRevert(SafeAuthorityGraph.NonCanonicalAuthorityGraph.selector);
        h.requireCanonical(duplicateRecords);

        SafeAuthorityRecord memory unreachableRecord =
            Records.record(address(0xD1), 1, Records.eoaOwners(Records.pks(4, 5)));
        vm.expectRevert(SafeAuthorityGraph.NonCanonicalAuthorityGraph.selector);
        h.requireCanonical(Records.list(twoRecords[0], twoRecords[1], unreachableRecord));
    }

    /// @notice Mark a recorded Safe as an EOA owner elsewhere in the graph.
    /// @dev One source address must not acquire conflicting verification kinds in the same
    ///      snapshot.
    function test_anEoaKindOwnerWithARecordRefuses() public {
        SafeAuthorityRecord[] memory records = _two();
        records[0].owners[0].kind = OWNER_EOA;
        vm.expectRevert(abi.encodeWithSelector(SafeAuthorityGraph.NonCanonicalAuthorityGraph.selector));
        h.requireCanonical(records);
    }

    /// @notice Assign an unsupported owner-kind value.
    /// @dev Graph validation must fail closed rather than choosing an unintended signature
    ///      path.
    function test_anUnknownKindRefuses() public {
        SafeAuthorityRecord[] memory records = _two();
        records[0].owners[1].kind = 2;
        vm.expectRevert(abi.encodeWithSelector(SafeAuthorityGraph.InvalidOwnerKind.selector, address(0xA0), a1));
        h.requireCanonical(records);
    }

    /// @notice Change owner kind, record order and threshold independently.
    /// @dev Every authority-relevant difference must affect the signed address commitment.
    function test_kindOrderAndThresholdEachChangeTheHash() public view {
        SafeAuthorityRecord[] memory records = _two();
        bytes32 base = h.hash(records);

        SafeAuthorityRecord[] memory permuted = _two();
        (permuted[1].owners[0], permuted[1].owners[1]) = (permuted[1].owners[1], permuted[1].owners[0]);
        assertTrue(h.hash(permuted) != base);

        SafeAuthorityRecord[] memory threshold = _two();
        threshold[1].threshold = 2;
        assertTrue(h.hash(threshold) != base);

        SafeAuthorityRecord[] memory kind = _two();
        kind[0].owners[1].kind = OWNER_SAFE;
        assertTrue(h.hash(kind) != base);

        assertEq(base, keccak256(abi.encode(records)));
    }
}
