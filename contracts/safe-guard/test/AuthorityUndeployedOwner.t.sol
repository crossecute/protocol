// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {AuthorityGraph} from "crossecute/messaging/authority/AuthorityGraph.sol";
import {ChildUpdate} from "crossecute/messaging/authority/ChildUpdate.sol";
import {Call} from "crossecute/messaging/Call.sol";
import {SafeQuorum} from "crossecute/messaging/signed/SafeQuorum.sol";
import {
    OWNER_EOA,
    OWNER_SAFE,
    SafeAuthorityRecord,
    SafeOwner
} from "crossecute/messaging/signed/types/SafeAuthorityTypes.sol";
import {AuthorityUpdate} from "../src/authority/AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "../src/authority/ISourceAuthorityGuard.sol";
import {Batch} from "./Batch.sol";
import {SourceAuthorityBase} from "./SourceAuthorityBase.sol";

/// @dev T16: an owner added while its address has no code is EOA-kind. A Safe deployed there later
///      passes Safe's own check with a contract signature, but the stored kind keeps it out of the
///      portable quorum until a later update re-adds it as Safe-kind.
contract AuthorityUndeployedOwnerTest is SourceAuthorityBase {
    uint256 private constant KEY_A = 0xA11CE;
    uint256 private constant KEY_X = 0x5AFE;
    uint256 private constant X_SALT_NONCE = 0xDEAD;
    address private constant SENTINEL = address(1);

    Safe private a;
    address private x;
    bytes private xSetup;

    function setUp() public override {
        super.setUp();
        uint256[] memory keys = new uint256[](1);
        keys[0] = KEY_A;
        a = _guarded(keys, 1);
        _activate(a, _signers(KEY_A));

        address[] memory xOwners = new address[](1);
        xOwners[0] = vm.addr(KEY_X);
        xSetup = abi.encodeCall(
            Safe.setup, (xOwners, 1, address(0), "", address(handler), address(0), 0, payable(address(0)))
        );
        x = vm.computeCreate2Address(
            keccak256(abi.encodePacked(keccak256(xSetup), X_SALT_NONCE)),
            keccak256(abi.encodePacked(factory.proxyCreationCode(), uint256(uint160(address(singleton))))),
            address(factory)
        );
    }

    function _signers(uint256 key) private pure returns (Signer[] memory signers) {
        signers = new Signer[](1);
        signers[0] = _eoa(key);
    }

    function _xSigner(Safe xSafe) private pure returns (Signer[] memory signers) {
        uint256[] memory keys = new uint256[](1);
        keys[0] = KEY_X;
        signers = new Signer[](1);
        signers[0] = _child(xSafe, keys);
    }

    function _record(uint8 xKind) private view returns (SafeAuthorityRecord memory) {
        SafeOwner[] memory owners = new SafeOwner[](2);
        owners[0] = SafeOwner(x, xKind);
        owners[1] = SafeOwner(vm.addr(KEY_A), OWNER_EOA);
        return SafeAuthorityRecord(address(a), 1, owners);
    }

    function _selectCalls(AuthorityGraph memory graph, Signer[] memory signers)
        private
        returns (bytes32 digest, bytes memory signatures, Batch.Call[] memory calls)
    {
        bytes memory data =
            abi.encodeCall(ISourceAuthorityGuard.selectAuthority, (AuthorityUpdate(_head(a), _hash(graph))));
        digest = _txHash(a, address(guard), 0, data, Enum.Operation.Call);
        signatures = _sign(signers, digest);
        calls = _stagedCalls(
            a, address(guard), data, Enum.Operation.Call, graph, new ChildUpdate[](0), signatures, signatures
        );
    }

    function testDeployedLaterStaysEoaKindUntilReadded() public {
        assertEq(x.code.length, 0);
        Call[] memory mutations = new Call[](1);
        mutations[0] = _call(address(a), abi.encodeCall(a.addOwnerWithThreshold, (x, 1)));
        AuthorityGraph memory eoaKind = _graph(_record(OWNER_EOA));
        _execOwnershipChange(a, eoaKind, mutations, _signers(KEY_A));

        Safe xSafe = Safe(payable(address(factory.createProxyWithNonce(address(singleton), xSetup, X_SALT_NONCE))));
        assertEq(address(xSafe), x);

        (bytes32 digest, bytes memory signatures, Batch.Call[] memory calls) = _selectCalls(eoaKind, _xSigner(xSafe));
        a.checkSignatures(address(0), digest, signatures);
        bytes32 head = _head(a);
        uint256 nonce = a.nonce();
        vm.expectRevert(abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, address(a), x));
        batch.run(calls);
        assertEq(a.nonce(), nonce);
        assertEq(_head(a), head);

        // X activates as a Safe, and A swaps the EOA-kind entry for a Safe-kind one in one batch.
        _install(xSafe, _signers(KEY_X), guard, _permissiveConfig(), true);
        _activate(xSafe, _signers(KEY_X));
        AuthorityGraph memory safeKind = _graph(_record(OWNER_SAFE), _record(xSafe), _head(xSafe));
        mutations = new Call[](2);
        mutations[0] = _call(address(a), abi.encodeCall(a.removeOwner, (SENTINEL, x, 1)));
        mutations[1] = _call(address(a), abi.encodeCall(a.addOwnerWithThreshold, (x, 1)));
        _execOwnershipChange(a, safeKind, mutations, _signers(KEY_A));

        (,, calls) = _selectCalls(safeKind, _xSigner(xSafe));
        batch.run(calls);
        assertEq(guard.selection(address(a)).authorityHash, _hash(safeKind));
    }
}
