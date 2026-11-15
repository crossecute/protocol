// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {SafeTx, SignedSafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {
    AuthoritySelection,
    AuthorityUpdate,
    SafeCreationProof
} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "@crossecute/safe-guard/authority/ISourceAuthorityGuard.sol";
import {Call} from "src/messaging/Call.sol";
import {AuthorityGraph, AuthorityNode} from "src/messaging/authority/AuthorityGraph.sol";
import {ChildUpdate} from "src/messaging/authority/ChildUpdate.sol";
import {AuthorityRegistryTemplate} from "src/messaging/authority/AuthorityRegistryTemplate.sol";
import {AuthorityUpdateEncoding} from "src/messaging/authority/AuthorityUpdateEncoding.sol";
import {SafeOwner, SafeAuthorityRecord, OWNER_EOA} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {SafeTxEvidence, NestedSafeApproval} from "src/messaging/signed/types/SignedDispatchTypes.sol";

/// @dev Test-only concrete hooks, restricted to a root with one EOA owner and no descendants.
///      Ownership changes are a single swapOwner. Not a production verifier: the creation proof's
///      address derivation and the flat child-update pass are not modelled.
contract AuthorityRegistryFixture is AuthorityRegistryTemplate {
    address internal constant GUARD = address(0x1234);
    address internal constant MULTISEND = address(0x5678);
    address internal constant SENTINEL = address(1);
    bool public busy;

    function setBusy(bool value) external {
        busy = value;
    }

    function _recognizeUpdate(uint256, address sourceSafe, SafeTxEvidence calldata e)
        internal
        pure
        override
        returns (UpdateKind, AuthorityUpdate memory)
    {
        SafeTx calldata tx_ = e.signedSafeTx.safeTx;
        require(tx_.value == 0, "wrong source call");
        if (tx_.to == MULTISEND && tx_.operation == 1) {
            (AuthorityUpdate memory update,) = AuthorityUpdateEncoding.decodeOwnershipBatch(GUARD, sourceSafe, tx_.data);
            return (UpdateKind.OwnershipChange, update);
        }
        require(tx_.to == GUARD && tx_.operation == 0, "wrong source call");
        bytes4 selector = bytes4(tx_.data);
        if (selector == ISourceAuthorityGuard.activate.selector) {
            (bytes32 authorityHash,) = abi.decode(tx_.data[4:], (bytes32, SafeCreationProof));
            return (UpdateKind.Activation, AuthorityUpdate(bytes32(0), authorityHash));
        }
        require(selector == ISourceAuthorityGuard.selectAuthority.selector, "wrong selector");
        return (UpdateKind.Selection, abi.decode(tx_.data[4:], (AuthorityUpdate)));
    }

    function _authenticateGraph(
        uint256,
        bytes32 currentAuthorityHash,
        UpdateKind kind,
        SafeTxEvidence calldata e,
        AuthorityGraph calldata newGraph,
        ChildUpdate[] calldata childUpdates
    ) internal view override {
        require(childUpdates.length == 0 && newGraph.nodes.length == 1, "fixture root only");
        SafeAuthorityRecord calldata next = newGraph.nodes[0].record;
        require(next.threshold == 1 && next.owners.length == 1, "fixture quorum only");
        require(next.owners[0].kind == OWNER_EOA, "fixture EOA only");
        address expected;
        if (kind == UpdateKind.Activation) {
            expected = _creationOwner(e);
        } else {
            address stored = graph(currentAuthorityHash).nodes[0].record.owners[0].owner;
            expected = kind == UpdateKind.Selection ? stored : _swappedOwner(next.safe, stored, e);
        }
        require(next.owners[0].owner == expected, "root record mismatch");
    }

    function _verifyUpdateSignatures(
        uint256 chain,
        bytes32 currentAuthorityHash,
        UpdateKind kind,
        SafeTxEvidence calldata e,
        AuthorityGraph calldata newGraph
    ) internal view override {
        address voter = kind == UpdateKind.Activation
            ? _creationOwner(e)
            : graph(currentAuthorityHash).nodes[0].record.owners[0].owner;
        bytes32 digest = SafeHashes.transactionHash(e.signedSafeTx.safeTx, newGraph.nodes[0].record.safe, chain);
        require(ECDSA.recover(digest, e.signedSafeTx.signatures) == voter, "wrong current signer");
    }

    function _requireAuthorityContextIdle(uint256, address) internal view override {
        require(!busy, "application context busy");
    }

    /// @dev Reads setup's owners and threshold; the fixture does not check the CREATE2 address.
    function _creationOwner(SafeTxEvidence calldata e) private pure returns (address) {
        (, SafeCreationProof memory creation) = abi.decode(e.signedSafeTx.safeTx.data[4:], (bytes32, SafeCreationProof));
        bytes memory initializer = creation.initializer;
        (address[] memory owners, uint256 threshold) = abi.decode(_tail(initializer), (address[], uint256));
        require(owners.length == 1 && threshold == 1, "fixture creation only");
        return owners[0];
    }

    function _swappedOwner(address safe, address stored, SafeTxEvidence calldata e) private pure returns (address) {
        (, Call[] memory mutations) =
            AuthorityUpdateEncoding.decodeOwnershipBatch(GUARD, safe, e.signedSafeTx.safeTx.data);
        require(mutations.length == 1, "fixture single swap");
        bytes memory data = mutations[0].data;
        require(bytes4(data) == AuthorityUpdateEncoding.SWAP_OWNER, "fixture single swap");
        (address prev, address oldOwner, address newOwner) = abi.decode(_tail(data), (address, address, address));
        require(prev == SENTINEL && oldOwner == stored, "fixture single swap");
        return newOwner;
    }

    function _tail(bytes memory data) private pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }
}

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

contract AuthorityRegistryTemplateTest is Test {
    uint256 internal constant CHAIN = 1;
    address internal constant SAFE = address(0xAAAA);
    address internal constant GUARD = address(0x1234);
    address internal constant MULTISEND = address(0x5678);
    address internal constant SENTINEL = address(1);
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

    function _sign(SafeTx memory tx_, uint256 key, uint256 chain) internal pure returns (SafeTxEvidence memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, SafeHashes.transactionHash(tx_, SAFE, chain));
        return SafeTxEvidence(SignedSafeTx(tx_, abi.encodePacked(r, s, v)), new NestedSafeApproval[](0));
    }

    function _creation(address owner) internal pure returns (SafeCreationProof memory) {
        address[] memory owners = new address[](1);
        owners[0] = owner;
        bytes memory initializer = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            1,
            address(0),
            "",
            address(0),
            address(0),
            0,
            address(0)
        );
        return SafeCreationProof(address(0x5AFE), initializer, 0);
    }

    function _activation(uint256 chain, uint256 creationKey, uint256 signerKey)
        internal
        pure
        returns (SafeTxEvidence memory)
    {
        address owner = vm.addr(creationKey);
        SafeTx memory tx_;
        tx_.to = GUARD;
        tx_.data = abi.encodeCall(
            ISourceAuthorityGuard.activate, (AuthorityUpdateEncoding.graphHash(chain, _graph(owner)), _creation(owner))
        );
        return _sign(tx_, signerKey, chain);
    }

    /// @dev An ownership change swapping the single owner `from` for `to`.
    function _rotation(AuthorityUpdate memory u, address from, address to, uint256 key, uint256 nonce, uint256 chain)
        internal
        pure
        returns (SafeTxEvidence memory)
    {
        Call[] memory mutations = new Call[](1);
        mutations[0] = Call(SAFE, 0, abi.encodeWithSignature("swapOwner(address,address,address)", SENTINEL, from, to));
        SafeTx memory tx_;
        tx_.to = MULTISEND;
        tx_.operation = 1;
        tx_.data = AuthorityUpdateEncoding.ownershipBatchData(GUARD, SAFE, u, mutations);
        tx_.nonce = nonce;
        return _sign(tx_, key, chain);
    }

    function _selection(AuthorityUpdate memory u, uint256 key, uint256 nonce)
        internal
        pure
        returns (SafeTxEvidence memory)
    {
        SafeTx memory tx_;
        tx_.to = GUARD;
        tx_.data = abi.encodeCall(ISourceAuthorityGuard.selectAuthority, (u));
        tx_.nonce = nonce;
        return _sign(tx_, key, CHAIN);
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
        return SafeHashes.transactionHash(e.signedSafeTx.safeTx, SAFE, CHAIN);
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

    function testSelectionCannotChangeRootRecord() public {
        AuthorityUpdate memory u = _update(registry, CHAIN, vm.addr(BOB_KEY));
        vm.expectRevert("root record mismatch");
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
