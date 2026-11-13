// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {SafeTx, SignedSafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {AuthoritySelection, AuthorityUpdate} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "@crossecute/safe-guard/authority/ISourceAuthorityGuard.sol";
import {Call} from "src/messaging/Call.sol";
import {AuthorityGraph} from "src/messaging/authority/AuthorityGraph.sol";
import {AuthorityRegistryTemplate} from "src/messaging/authority/AuthorityRegistryTemplate.sol";
import {AuthorityUpdateEncoding} from "src/messaging/authority/AuthorityUpdateEncoding.sol";
import {SafeOwner, SafeAuthorityRecord, OWNER_EOA} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {SafeTxEvidence, NestedSafeApproval} from "src/messaging/signed/types/SignedDispatchTypes.sol";

/// @dev Test-only concrete hooks, restricted to one EOA owner. Not a production graph/genesis verifier.
contract AuthorityRegistryFixture is AuthorityRegistryTemplate {
    address internal constant GUARD = address(0x1234);
    bool public busy;

    function initialize(uint256 chain, address safe, AuthorityGraph calldata authority) external {
        _initializeAuthority(chain, safe, authority, "");
    }

    function setBusy(bool value) external {
        busy = value;
    }

    function _verifySignedUpdate(
        uint256 chain,
        address safe,
        AuthoritySelection memory current,
        SafeTxEvidence calldata e
    ) internal view override returns (AuthorityUpdate memory) {
        SafeTx memory tx_ = e.signedSafeTx.safeTx;
        require(tx_.to == GUARD && tx_.value == 0 && tx_.operation == 0, "wrong source call");
        require(bytes4(tx_.data) == ISourceAuthorityGuard.selectAuthority.selector, "wrong selector");
        AuthorityGraph memory oldGraph = this.graph(current.authorityHash);
        address signer = ECDSA.recover(SafeHashes.transactionHash(tx_, safe, chain), e.signedSafeTx.signatures);
        require(signer == oldGraph.records[0].owners[0].owner, "wrong current signer");
        return abi.decode(e.signedSafeTx.safeTx.data[4:], (AuthorityUpdate));
    }

    function _authenticateGraph(uint256, address safe, AuthorityGraph calldata authority, bytes calldata)
        internal
        pure
        override
    {
        _checkFixtureGraph(safe, authority);
    }

    function _authenticateGenesis(uint256, address safe, AuthorityGraph calldata authority, bytes memory)
        internal
        pure
        override
    {
        // Fixture-only bootstrap; does not model deterministic Safe creation proof.
        _checkFixtureGraph(safe, authority);
    }

    function _checkFixtureGraph(address safe, AuthorityGraph calldata authority) private pure {
        require(authority.records.length == 1 && authority.records[0].safe == safe, "fixture graph only");
        require(authority.records[0].threshold == 1 && authority.records[0].owners.length == 1, "fixture quorum only");
        require(authority.records[0].owners[0].kind == OWNER_EOA, "fixture EOA only");
    }

    function _requireAuthorityContextIdle(uint256, address) internal view override {
        require(!busy, "application context busy");
    }
}

contract AuthorityEncodingFixture {
    function mutationData(address safe, Call[] memory calls) external pure returns (bytes memory) {
        return AuthorityUpdateEncoding.mutationBatchData(safe, calls);
    }
}

contract AuthorityRegistryTemplateTest is Test {
    uint256 internal constant CHAIN = 1;
    address internal constant SAFE = address(0xAAAA);
    uint256 internal constant ALICE_KEY = 1;
    uint256 internal constant BOB_KEY = 2;
    AuthorityRegistryFixture internal registry;
    AuthorityEncodingFixture internal encoding;

    function setUp() public {
        registry = new AuthorityRegistryFixture();
        encoding = new AuthorityEncodingFixture();
        registry.initialize(CHAIN, SAFE, _graph(vm.addr(ALICE_KEY)));
    }

    function _graph(address owner) internal pure returns (AuthorityGraph memory g) {
        g.rootSafe = SAFE;
        g.records = new SafeAuthorityRecord[](1);
        SafeOwner[] memory owners = new SafeOwner[](1);
        owners[0] = SafeOwner(owner, OWNER_EOA);
        g.records[0] = SafeAuthorityRecord(SAFE, 1, owners);
    }

    function _evidence(AuthorityUpdate memory u, uint256 key, uint256 nonce)
        internal
        pure
        returns (SafeTxEvidence memory e)
    {
        SafeTx memory tx_;
        tx_.to = address(0x1234);
        tx_.data = abi.encodeCall(ISourceAuthorityGuard.selectAuthority, (u));
        tx_.nonce = nonce;
        bytes32 digest = SafeHashes.transactionHash(tx_, SAFE, CHAIN);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        e = SafeTxEvidence(SignedSafeTx(tx_, abi.encodePacked(r, s, v)), new NestedSafeApproval[](0));
    }

    function _update(AuthorityRegistryFixture target, address nextOwner)
        internal
        view
        returns (AuthorityUpdate memory u)
    {
        AuthoritySelection memory current = target.selection(CHAIN, SAFE);
        u = AuthorityUpdate(
            current.updateHead, current.authorityHash, AuthorityUpdateEncoding.graphHash(CHAIN, _graph(nextOwner))
        );
    }

    function testLinkedHandoffsRejectSecondFirstWithoutStateChange() public {
        AuthorityUpdate memory u1 = _update(registry, vm.addr(BOB_KEY));
        SafeTxEvidence memory e1 = _evidence(u1, ALICE_KEY, 10);
        bytes32 h1 = SafeHashes.transactionHash(e1.signedSafeTx.safeTx, SAFE, CHAIN);
        AuthorityUpdate memory u2 = AuthorityUpdate(h1, u1.newAuthorityHash, u1.previousAuthorityHash);
        SafeTxEvidence memory e2 = _evidence(u2, BOB_KEY, 12);
        bytes32 initialHead = registry.selection(CHAIN, SAFE).updateHead;
        vm.expectRevert();
        registry.submitAuthority(CHAIN, SAFE, e2, _graph(vm.addr(ALICE_KEY)), "");
        assertEq(registry.selection(CHAIN, SAFE).updateHead, initialHead);
        registry.submitAuthority(CHAIN, SAFE, e1, _graph(vm.addr(BOB_KEY)), "");
        registry.submitAuthority(CHAIN, SAFE, e2, _graph(vm.addr(ALICE_KEY)), "");
        assertEq(registry.selection(CHAIN, SAFE).authorityHash, u2.newAuthorityHash);
    }

    function testHugeSignedNonceDoesNotBlockLinkedLowerNonce() public {
        AuthorityUpdate memory u1 = _update(registry, vm.addr(BOB_KEY));
        registry.submitAuthority(CHAIN, SAFE, _evidence(u1, ALICE_KEY, type(uint256).max), _graph(vm.addr(BOB_KEY)), "");
        AuthorityUpdate memory u2 = _update(registry, vm.addr(ALICE_KEY));
        registry.submitAuthority(CHAIN, SAFE, _evidence(u2, BOB_KEY, 11), _graph(vm.addr(ALICE_KEY)), "");
        assertEq(registry.selection(CHAIN, SAFE).authorityHash, u2.newAuthorityHash);
    }

    function testSameSignedUpdateReusableOnAnotherDestinationRegistry() public {
        AuthorityRegistryFixture other = new AuthorityRegistryFixture();
        other.initialize(CHAIN, SAFE, _graph(vm.addr(ALICE_KEY)));
        AuthorityUpdate memory u = _update(registry, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _evidence(u, ALICE_KEY, 20);
        registry.submitAuthority(CHAIN, SAFE, e, _graph(vm.addr(BOB_KEY)), "");
        other.submitAuthority(CHAIN, SAFE, e, _graph(vm.addr(BOB_KEY)), "");
        assertEq(registry.selection(CHAIN, SAFE).updateHead, other.selection(CHAIN, SAFE).updateHead);
    }

    function testReplayBlockedAfterOriginalGraphReturns() public {
        AuthorityUpdate memory u1 = _update(registry, vm.addr(BOB_KEY));
        SafeTxEvidence memory e1 = _evidence(u1, ALICE_KEY, 10);
        registry.submitAuthority(CHAIN, SAFE, e1, _graph(vm.addr(BOB_KEY)), "");
        AuthorityUpdate memory u2 = _update(registry, vm.addr(ALICE_KEY));
        registry.submitAuthority(CHAIN, SAFE, _evidence(u2, BOB_KEY, 12), _graph(vm.addr(ALICE_KEY)), "");
        vm.expectRevert(AuthorityRegistryTemplate.UpdateAlreadyAccepted.selector);
        registry.submitAuthority(CHAIN, SAFE, e1, _graph(vm.addr(BOB_KEY)), "");
    }

    function testCompetingSuccessorCannotOverwriteAcceptedBranch() public {
        AuthorityUpdate memory first = _update(registry, vm.addr(BOB_KEY));
        AuthorityUpdate memory competing = _update(registry, vm.addr(ALICE_KEY));
        SafeTxEvidence memory e = _evidence(competing, ALICE_KEY, 100);
        registry.submitAuthority(CHAIN, SAFE, _evidence(first, ALICE_KEY, 10), _graph(vm.addr(BOB_KEY)), "");
        vm.expectRevert();
        registry.submitAuthority(CHAIN, SAFE, e, _graph(vm.addr(ALICE_KEY)), "");
    }

    function testNewOwnersCannotSelfInstall() public {
        AuthorityUpdate memory u = _update(registry, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _evidence(u, BOB_KEY, 10);
        vm.expectRevert("wrong current signer");
        registry.submitAuthority(CHAIN, SAFE, e, _graph(vm.addr(BOB_KEY)), "");
    }

    function testAlteredReplacementGraphRejected() public {
        AuthorityUpdate memory u = _update(registry, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _evidence(u, ALICE_KEY, 10);
        vm.expectRevert(AuthorityRegistryTemplate.ReplacementHashMismatch.selector);
        registry.submitAuthority(CHAIN, SAFE, e, _graph(vm.addr(ALICE_KEY)), "");
    }

    function testWrongSourceChainCannotReuseSignature() public {
        registry.initialize(10, SAFE, _graph(vm.addr(ALICE_KEY)));
        AuthorityUpdate memory u = _update(registry, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _evidence(u, ALICE_KEY, 10);
        vm.expectRevert("wrong current signer");
        registry.submitAuthority(10, SAFE, e, _graph(vm.addr(BOB_KEY)), "");
    }

    function testBusyContextBlocksUpdate() public {
        AuthorityUpdate memory u = _update(registry, vm.addr(BOB_KEY));
        SafeTxEvidence memory e = _evidence(u, ALICE_KEY, 10);
        registry.setBusy(true);
        vm.expectRevert("application context busy");
        registry.submitAuthority(CHAIN, SAFE, e, _graph(vm.addr(BOB_KEY)), "");
    }

    function testCannotReinitializeSelection() public {
        vm.expectRevert(AuthorityRegistryTemplate.AlreadyRegistered.selector);
        registry.initialize(CHAIN, SAFE, _graph(vm.addr(BOB_KEY)));
    }

    function testMutationBatchPacksSelfCallsInOrder() public view {
        Call[] memory calls = new Call[](2);
        calls[0] = Call(SAFE, 0, abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", address(0xB), 1));
        calls[1] = Call(SAFE, 0, abi.encodeWithSignature("changeThreshold(uint256)", 2));
        bytes memory expected = abi.encodeWithSignature(
            "multiSend(bytes)",
            bytes.concat(
                abi.encodePacked(uint8(0), SAFE, uint256(0), calls[0].data.length, calls[0].data),
                abi.encodePacked(uint8(0), SAFE, uint256(0), calls[1].data.length, calls[1].data)
            )
        );
        assertEq(encoding.mutationData(SAFE, calls), expected);
    }

    function testMutationBatchRejectsExternalTargetValueAndUnknownSelector() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(0xB), 0, abi.encodeWithSignature("changeThreshold(uint256)", 1));
        vm.expectRevert(abi.encodeWithSelector(AuthorityUpdateEncoding.InvalidMutation.selector, 0));
        encoding.mutationData(SAFE, calls);
        calls[0].target = SAFE;
        calls[0].value = 1;
        vm.expectRevert(abi.encodeWithSelector(AuthorityUpdateEncoding.InvalidMutation.selector, 0));
        encoding.mutationData(SAFE, calls);
        calls[0].value = 0;
        calls[0].data = abi.encodeWithSignature("setGuard(address)", address(0xB));
        vm.expectRevert(abi.encodeWithSelector(AuthorityUpdateEncoding.InvalidMutation.selector, 0));
        encoding.mutationData(SAFE, calls);
    }
}
