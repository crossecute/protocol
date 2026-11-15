// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {
    AuthoritySelection,
    AuthorityUpdate,
    SafeCreationProof
} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "@crossecute/safe-guard/authority/ISourceAuthorityGuard.sol";
import {Call} from "src/messaging/Call.sol";
import {AuthorityGraph, AuthorityNode} from "src/messaging/authority/AuthorityGraph.sol";
import {AuthorityMutations} from "src/messaging/authority/AuthorityMutations.sol";
import {ChildUpdate} from "src/messaging/authority/ChildUpdate.sol";
import {AuthorityRegistryTemplate} from "src/messaging/authority/AuthorityRegistryTemplate.sol";
import {AuthorityUpdateEncoding} from "src/messaging/authority/AuthorityUpdateEncoding.sol";
import {SafeOwner, SafeAuthorityRecord, OWNER_EOA} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {SafeTxEvidence} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {AuthorityRegistryFixture, AuthorityRegistryTestBase} from "./AuthorityRegistryFixture.sol";

contract AuthorityEncodingFixture {
    function ownershipBatchData(address guard, address safe, AuthorityUpdate memory update, Call[] memory calls)
        external
        pure
        returns (bytes memory)
    {
        return AuthorityUpdateEncoding.ownershipBatchData(guard, safe, update, calls);
    }

    function decodeOwnershipBatch(address guard, address safe, bytes memory data)
        external
        pure
        returns (AuthorityUpdate memory, Call[] memory)
    {
        return AuthorityUpdateEncoding.decodeOwnershipBatch(guard, safe, data);
    }
}

/// @dev A root with one EOA owner and no descendants; graph-pass cases are in AuthorityGraphPass.t.sol.
contract AuthorityRegistryTemplateTest is AuthorityRegistryTestBase {
    // The factory address of _creation(ALICE_KEY); testActivationSafeTxHashIsFirstHead checks it.
    address internal constant SAFE = 0x21D9c001b9233ead0386c40BD1ACe1F3E6733E3D;
    uint256 internal constant ALICE_KEY = 1;
    uint256 internal constant BOB_KEY = 2;
    AuthorityRegistryFixture internal registry;
    AuthorityEncodingFixture internal encoding;
    SafeTxEvidence internal activation;

    function setUp() public {
        registry = new AuthorityRegistryFixture();
        encoding = new AuthorityEncodingFixture();
        activation = _activation(CHAIN, ALICE_KEY, ALICE_KEY);
        _submit(registry, CHAIN, activation, vm.addr(ALICE_KEY));
    }

    function _graph(address owner) internal pure returns (AuthorityGraph memory g) {
        SafeOwner[] memory owners = new SafeOwner[](1);
        owners[0] = SafeOwner(owner, OWNER_EOA);
        g.nodes = new AuthorityNode[](1);
        g.nodes[0] = AuthorityNode(SafeAuthorityRecord(SAFE, 1, owners), bytes32(0));
    }

    function _submit(AuthorityRegistryFixture target, uint256 chain, SafeTxEvidence memory e, address owner) internal {
        target.submitAuthority(chain, SAFE, e, _graph(owner), new ChildUpdate[](0));
    }

    function _creation(uint256 key) internal pure returns (SafeCreationProof memory) {
        address[] memory owners = new address[](1);
        owners[0] = vm.addr(key);
        return _creation(owners, 1);
    }

    function _activation(uint256 chain, uint256 creationKey, uint256 signerKey)
        internal
        pure
        returns (SafeTxEvidence memory)
    {
        SafeTx memory tx_ = _activationTx(chain, _graph(vm.addr(creationKey)), _creation(creationKey));
        return _sign(tx_, SAFE, chain, signerKey);
    }

    /// @dev An ownership change swapping the single owner `from` for `to`.
    function _rotation(AuthorityUpdate memory u, address from, address to, uint256 key, uint256 nonce, uint256 chain)
        internal
        pure
        returns (SafeTxEvidence memory)
    {
        Call[] memory mutations = new Call[](1);
        mutations[0] = Call(SAFE, 0, abi.encodeWithSignature("swapOwner(address,address,address)", SENTINEL, from, to));
        return _sign(_ownershipTx(SAFE, u, mutations, nonce), SAFE, chain, key);
    }

    function _selection(AuthorityUpdate memory u, uint256 key, uint256 nonce)
        internal
        pure
        returns (SafeTxEvidence memory)
    {
        return _sign(_selectionTx(u, nonce), SAFE, CHAIN, key);
    }

    function _update(AuthorityRegistryFixture target, uint256 chain, address nextOwner)
        internal
        view
        returns (AuthorityUpdate memory)
    {
        return AuthorityUpdate(
            target.selection(chain, SAFE).updateHead, AuthorityUpdateEncoding.graphHash(chain, _graph(nextOwner))
        );
    }

    function _hash(SafeTxEvidence memory e) internal pure returns (bytes32) {
        return _hash(e, SAFE);
    }

    function testLinkedHandoffsRejectSecondFirstWithoutStateChange() public {
        address alice = vm.addr(ALICE_KEY);
        address bob = vm.addr(BOB_KEY);
        AuthorityUpdate memory u1 = _update(registry, CHAIN, bob);
        SafeTxEvidence memory e1 = _rotation(u1, alice, bob, ALICE_KEY, 10, CHAIN);
        AuthorityUpdate memory u2 = AuthorityUpdate(_hash(e1), AuthorityUpdateEncoding.graphHash(CHAIN, _graph(alice)));
        SafeTxEvidence memory e2 = _rotation(u2, bob, alice, BOB_KEY, 12, CHAIN);
        bytes32 initialHead = registry.selection(CHAIN, SAFE).updateHead;
        vm.expectRevert(AuthorityRegistryTemplate.PreviousUpdateMismatch.selector);
        _submit(registry, CHAIN, e2, alice);
        assertEq(registry.selection(CHAIN, SAFE).updateHead, initialHead);
        _submit(registry, CHAIN, e1, bob);
        _submit(registry, CHAIN, e2, alice);
        assertEq(registry.selection(CHAIN, SAFE).authorityHash, u2.newAuthorityHash);
    }

    function testHugeSignedNonceDoesNotBlockLinkedLowerNonce() public {
        address alice = vm.addr(ALICE_KEY);
        address bob = vm.addr(BOB_KEY);
        AuthorityUpdate memory u1 = _update(registry, CHAIN, bob);
        _submit(registry, CHAIN, _rotation(u1, alice, bob, ALICE_KEY, type(uint256).max, CHAIN), bob);
        AuthorityUpdate memory u2 = _update(registry, CHAIN, alice);
        _submit(registry, CHAIN, _rotation(u2, bob, alice, BOB_KEY, 11, CHAIN), alice);
        assertEq(registry.selection(CHAIN, SAFE).authorityHash, u2.newAuthorityHash);
    }

    function testSameSignedEvidenceReusableOnAnotherDestinationRegistry() public {
        AuthorityRegistryFixture other = new AuthorityRegistryFixture();
        _submit(other, CHAIN, activation, vm.addr(ALICE_KEY));
        AuthorityUpdate memory u = _update(registry, CHAIN, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _rotation(u, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), ALICE_KEY, 20, CHAIN);
        _submit(registry, CHAIN, e, vm.addr(BOB_KEY));
        _submit(other, CHAIN, e, vm.addr(BOB_KEY));
        assertEq(registry.selection(CHAIN, SAFE).updateHead, other.selection(CHAIN, SAFE).updateHead);
    }

    function testReplayBlockedAfterOriginalGraphReturns() public {
        address alice = vm.addr(ALICE_KEY);
        address bob = vm.addr(BOB_KEY);
        SafeTxEvidence memory e1 = _rotation(_update(registry, CHAIN, bob), alice, bob, ALICE_KEY, 10, CHAIN);
        _submit(registry, CHAIN, e1, bob);
        _submit(registry, CHAIN, _rotation(_update(registry, CHAIN, alice), bob, alice, BOB_KEY, 12, CHAIN), alice);
        vm.expectRevert(AuthorityRegistryTemplate.PreviousUpdateMismatch.selector);
        _submit(registry, CHAIN, e1, bob);
    }

    function testExactDuplicateOfHeadRejected() public {
        address bob = vm.addr(BOB_KEY);
        SafeTxEvidence memory e =
            _rotation(_update(registry, CHAIN, bob), vm.addr(ALICE_KEY), bob, ALICE_KEY, 10, CHAIN);
        _submit(registry, CHAIN, e, bob);
        AuthoritySelection memory accepted = registry.selection(CHAIN, SAFE);
        vm.expectRevert(AuthorityRegistryTemplate.PreviousUpdateMismatch.selector);
        _submit(registry, CHAIN, e, bob);
        assertEq(registry.selection(CHAIN, SAFE).updateHead, accepted.updateHead);
    }

    function testCompetingSuccessorCannotOverwriteAcceptedBranch() public {
        AuthorityUpdate memory first = _update(registry, CHAIN, vm.addr(BOB_KEY));
        AuthorityUpdate memory competing = _update(registry, CHAIN, vm.addr(ALICE_KEY));
        _submit(
            registry,
            CHAIN,
            _rotation(first, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), ALICE_KEY, 10, CHAIN),
            vm.addr(BOB_KEY)
        );
        vm.expectRevert(AuthorityRegistryTemplate.PreviousUpdateMismatch.selector);
        _submit(registry, CHAIN, _selection(competing, ALICE_KEY, 100), vm.addr(ALICE_KEY));
    }

    function testNewOwnersCannotSelfInstall() public {
        AuthorityUpdate memory u = _update(registry, CHAIN, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _rotation(u, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), BOB_KEY, 10, CHAIN);
        vm.expectRevert("wrong current signer");
        _submit(registry, CHAIN, e, vm.addr(BOB_KEY));
    }

    function testAlteredReplacementGraphRejected() public {
        AuthorityUpdate memory u = _update(registry, CHAIN, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _rotation(u, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), ALICE_KEY, 10, CHAIN);
        vm.expectRevert(AuthorityRegistryTemplate.ReplacementHashMismatch.selector);
        _submit(registry, CHAIN, e, vm.addr(ALICE_KEY));
    }

    function testOwnershipChangeRootMustBeMutationResult() public {
        // Signs a graph naming carol while its swap installs bob.
        AuthorityUpdate memory u = _update(registry, CHAIN, vm.addr(3));
        SafeTxEvidence memory e = _rotation(u, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), ALICE_KEY, 10, CHAIN);
        vm.expectRevert(AuthorityMutations.MutationResultMismatch.selector);
        _submit(registry, CHAIN, e, vm.addr(3));
    }

    function testSelectionCannotChangeRootRecord() public {
        AuthorityUpdate memory u = _update(registry, CHAIN, vm.addr(BOB_KEY));
        vm.expectRevert(AuthorityRegistryTemplate.RootRecordMismatch.selector);
        _submit(registry, CHAIN, _selection(u, ALICE_KEY, 10), vm.addr(BOB_KEY));
    }

    function testWrongSourceChainCannotReuseSignature() public {
        _submit(registry, 10, _activation(10, ALICE_KEY, ALICE_KEY), vm.addr(ALICE_KEY));
        // Chain 10's own predecessor and graph hash, signed under chain 1's Safe domain.
        AuthorityUpdate memory u = _update(registry, 10, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _rotation(u, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), ALICE_KEY, 10, CHAIN);
        vm.expectRevert("wrong current signer");
        _submit(registry, 10, e, vm.addr(BOB_KEY));
    }

    function testBusyContextBlocksUpdate() public {
        AuthorityUpdate memory u = _update(registry, CHAIN, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _rotation(u, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), ALICE_KEY, 10, CHAIN);
        registry.setBusy(true);
        vm.expectRevert("application context busy");
        _submit(registry, CHAIN, e, vm.addr(BOB_KEY));
    }

    function testRootMustBeFirstNodeAtPositionZero() public {
        AuthorityUpdate memory u = _update(registry, CHAIN, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _rotation(u, vm.addr(ALICE_KEY), vm.addr(BOB_KEY), ALICE_KEY, 10, CHAIN);
        AuthorityGraph memory g = _graph(vm.addr(BOB_KEY));
        g.nodes[0].record.safe = address(0xBBBB);
        vm.expectRevert(AuthorityRegistryTemplate.WrongRoot.selector);
        registry.submitAuthority(CHAIN, SAFE, e, g, new ChildUpdate[](0));
        g = _graph(vm.addr(BOB_KEY));
        g.nodes[0].position = bytes32(uint256(1));
        vm.expectRevert(AuthorityRegistryTemplate.RootPositionNotZero.selector);
        registry.submitAuthority(CHAIN, SAFE, e, g, new ChildUpdate[](0));
    }

    function testActivationSafeTxHashIsFirstHead() public view {
        assertEq(SAFE, _safeAddress(_creation(ALICE_KEY)), "fixture Safe address");
        AuthoritySelection memory current = registry.selection(CHAIN, SAFE);
        assertEq(current.updateHead, _hash(activation));
        assertEq(current.authorityHash, AuthorityUpdateEncoding.graphHash(CHAIN, _graph(vm.addr(ALICE_KEY))));
    }

    function testCannotActivateTwice() public {
        vm.expectRevert(AuthorityRegistryTemplate.AlreadyRegistered.selector);
        _submit(registry, CHAIN, activation, vm.addr(ALICE_KEY));
        SafeTxEvidence memory second = _activation(CHAIN, BOB_KEY, BOB_KEY);
        vm.expectRevert(AuthorityRegistryTemplate.AlreadyRegistered.selector);
        _submit(registry, CHAIN, second, vm.addr(BOB_KEY));
    }

    function testUpdateBeforeActivationRejected() public {
        AuthorityRegistryFixture other = new AuthorityRegistryFixture();
        AuthorityUpdate memory u =
            AuthorityUpdate(bytes32(0), AuthorityUpdateEncoding.graphHash(CHAIN, _graph(vm.addr(ALICE_KEY))));
        vm.expectRevert(AuthorityRegistryTemplate.UnregisteredAuthority.selector);
        _submit(other, CHAIN, _selection(u, ALICE_KEY, 0), vm.addr(ALICE_KEY));
    }

    function testActivationMustBeSignedByCreationOwners() public {
        AuthorityRegistryFixture other = new AuthorityRegistryFixture();
        vm.expectRevert("wrong current signer");
        _submit(other, CHAIN, _activation(CHAIN, ALICE_KEY, BOB_KEY), vm.addr(ALICE_KEY));
    }

    function testGraphAndRecordsReadBack() public {
        address alice = vm.addr(ALICE_KEY);
        address bob = vm.addr(BOB_KEY);
        _submit(registry, CHAIN, _rotation(_update(registry, CHAIN, bob), alice, bob, ALICE_KEY, 10, CHAIN), bob);
        AuthorityGraph memory stored = registry.graph(registry.selection(CHAIN, SAFE).authorityHash);
        assertEq(stored.nodes.length, 1);
        assertEq(stored.nodes[0].record.owners[0].owner, bob);
        bytes32 aliceRecord = AuthorityUpdateEncoding.recordHash(_graph(alice).nodes[0].record);
        assertEq(registry.record(aliceRecord).owners[0].owner, alice);
        vm.expectRevert(AuthorityRegistryTemplate.GraphNotCached.selector);
        registry.graph(bytes32(uint256(1)));
    }

    function testOwnershipBatchPacksGuardCallThenSelfCalls() public view {
        AuthorityUpdate memory u = AuthorityUpdate(bytes32(uint256(1)), bytes32(uint256(2)));
        Call[] memory calls = new Call[](2);
        calls[0] = Call(SAFE, 0, abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", address(0xB), 1));
        calls[1] = Call(SAFE, 0, abi.encodeWithSignature("changeThreshold(uint256)", 2));
        bytes memory registration = abi.encodeCall(ISourceAuthorityGuard.registerOwnershipChange, (u));
        bytes memory expected = abi.encodeWithSignature(
            "multiSend(bytes)",
            bytes.concat(
                abi.encodePacked(uint8(0), GUARD, uint256(0), registration.length, registration),
                abi.encodePacked(uint8(0), SAFE, uint256(0), calls[0].data.length, calls[0].data),
                abi.encodePacked(uint8(0), SAFE, uint256(0), calls[1].data.length, calls[1].data)
            )
        );
        bytes memory data = encoding.ownershipBatchData(GUARD, SAFE, u, calls);
        assertEq(data, expected);
        (AuthorityUpdate memory decoded, Call[] memory mutations) = encoding.decodeOwnershipBatch(GUARD, SAFE, data);
        assertEq(decoded.previousUpdateHash, u.previousUpdateHash);
        assertEq(decoded.newAuthorityHash, u.newAuthorityHash);
        assertEq(mutations.length, 2);
        assertEq(mutations[1].data, calls[1].data);
    }

    function testOwnershipBatchRejectsExternalTargetValueAndUnknownSelector() public {
        AuthorityUpdate memory u;
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(0xB), 0, abi.encodeWithSignature("changeThreshold(uint256)", 1));
        vm.expectRevert(abi.encodeWithSelector(AuthorityUpdateEncoding.InvalidMutation.selector, 0));
        encoding.ownershipBatchData(GUARD, SAFE, u, calls);
        calls[0].target = SAFE;
        calls[0].value = 1;
        vm.expectRevert(abi.encodeWithSelector(AuthorityUpdateEncoding.InvalidMutation.selector, 0));
        encoding.ownershipBatchData(GUARD, SAFE, u, calls);
        calls[0].value = 0;
        calls[0].data = abi.encodeWithSignature("setGuard(address)", address(0xB));
        vm.expectRevert(abi.encodeWithSelector(AuthorityUpdateEncoding.InvalidMutation.selector, 0));
        encoding.ownershipBatchData(GUARD, SAFE, u, calls);
    }

    function testOwnershipBatchDecodeRejectsOtherEncodings() public {
        AuthorityUpdate memory u;
        Call[] memory calls = new Call[](1);
        calls[0] = Call(SAFE, 0, abi.encodeWithSignature("changeThreshold(uint256)", 1));
        bytes memory data = encoding.ownershipBatchData(GUARD, SAFE, u, calls);
        // Another guard address.
        vm.expectRevert(AuthorityUpdateEncoding.InvalidOwnershipBatch.selector);
        encoding.decodeOwnershipBatch(address(0x9999), SAFE, data);
        // Trailing bytes after the multiSend argument.
        vm.expectRevert(AuthorityUpdateEncoding.InvalidOwnershipBatch.selector);
        encoding.decodeOwnershipBatch(GUARD, SAFE, bytes.concat(data, bytes1(0)));
        // The guard call alone, without a mutation.
        bytes memory registration = abi.encodeCall(ISourceAuthorityGuard.registerOwnershipChange, (u));
        bytes memory alone = abi.encodeWithSignature(
            "multiSend(bytes)", abi.encodePacked(uint8(0), GUARD, uint256(0), registration.length, registration)
        );
        vm.expectRevert(AuthorityUpdateEncoding.InvalidOwnershipBatch.selector);
        encoding.decodeOwnershipBatch(GUARD, SAFE, alone);
    }
}
