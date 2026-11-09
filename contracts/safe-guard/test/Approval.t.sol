// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {SafePolicyGuard} from "policy-engine/SafePolicyGuard.sol";
import {Operation} from "policy-engine/interfaces/Operation.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {SignMessageLib} from "safe-smart-account/libraries/SignMessageLib.sol";
import {ICrossecuteGuard} from "../src/ICrossecuteGuard.sol";
import {GuardTestBase} from "./GuardTestBase.sol";
import {TestTransmitter} from "./TestTransmitter.sol";

/// @dev Has `signMessage(bytes)` and writes nothing.
contract FakeSignLib {
    function signMessage(bytes calldata) external {}
}

/// @dev Runs a Safe transaction and then reverts, rolling back everything it caused.
contract Reverter {
    error RolledBack();

    function run(Safe safe, bytes calldata execCall) external {
        (bool success,) = address(safe).call(execCall);
        require(success);
        revert RolledBack();
    }
}

/// @dev A 2-of-3 child Safe owns a parent alongside one EOA. The child approves the parent's
///      transaction with `signMessage`, so the parent can carry an empty child payload.
contract ApprovalTest is GuardTestBase {
    Safe internal child;
    Safe internal parent;
    TestTransmitter internal parentTransmitter;
    FakeSignLib internal fake;

    function setUp() public override {
        super.setUp();
        fake = new FakeSignLib();
        address[] memory childOwners = new address[](3);
        childOwners[0] = vm.addr(KEY_A);
        childOwners[1] = vm.addr(KEY_B);
        childOwners[2] = vm.addr(KEY_C);
        child = _newSafe(childOwners, 2);
        _install(child, _signers(), guard, _childConfig(), false);

        address[] memory parentOwners = new address[](2);
        parentOwners[0] = vm.addr(KEY_A);
        parentOwners[1] = address(child);
        parent = _newSafe(parentOwners, 2);
        Signer[] memory installers = new Signer[](2);
        installers[0] = _eoa(KEY_A);
        uint256[] memory childKeys = new uint256[](2);
        childKeys[0] = KEY_B;
        childKeys[1] = KEY_C;
        installers[1] = _child(child, childKeys);
        _install(parent, installers, guard, _defaultConfig(), false);
        parentTransmitter = new TestTransmitter(address(parent), sink);
    }

    function test_approval_cachedWithoutPolicyExtension() public {
        bytes32 parentTxHash = _parentDispatchHash();
        bytes memory data = _signMessageCall(parentTxHash);
        uint256 nonce = child.nonce();
        bytes memory ownerSigs =
            _signFor(child, _signers(), address(signMessageLib), 0, data, Enum.Operation.DelegateCall);

        _execWith(
            child,
            address(signMessageLib),
            0,
            data,
            Enum.Operation.DelegateCall,
            _withPolicyContext(ownerSigs, hex"0102")
        );

        bytes32 messageHash = _childMessageHash(child, parentTxHash);
        assertEq(child.signedMessages(messageHash), 1);
        ICrossecuteGuard.SignedSafeTx memory evidence = guard.getApproval(address(child), messageHash);
        assertEq(evidence.safeTx.to, address(signMessageLib));
        assertEq(evidence.safeTx.operation, uint8(Operation.DELEGATECALL));
        assertEq(evidence.safeTx.value, 0);
        assertEq(evidence.safeTx.data, data);
        assertEq(evidence.safeTx.nonce, nonce);
        assertEq(evidence.signatures, ownerSigs);
        // The cached fields reproduce the hash the child owners signed.
        assertEq(
            child.getTransactionHash(
                evidence.safeTx.to,
                evidence.safeTx.value,
                evidence.safeTx.data,
                Enum.Operation(evidence.safeTx.operation),
                evidence.safeTx.safeTxGas,
                evidence.safeTx.baseGas,
                evidence.safeTx.gasPrice,
                evidence.safeTx.gasToken,
                payable(evidence.safeTx.refundReceiver),
                evidence.safeTx.nonce
            ),
            _txHashAt(child, address(signMessageLib), 0, data, Enum.Operation.DelegateCall, nonce)
        );
    }

    /// @dev Every payment field is distinct and nonzero, so a swapped or dropped field fails.
    function test_approval_recordsEverySignedField() public {
        bytes memory data = _signMessageCall(bytes32(uint256(7)));
        uint256 nonce = child.nonce();
        Payment memory payment = Payment(4242, address(0xCAFE), payable(address(0xF00D)));
        (bytes32 txHash, bytes memory signatures) =
            _execPaid(child, _signers(), address(signMessageLib), 0, data, Enum.Operation.DelegateCall, payment);

        ICrossecuteGuard.SignedSafeTx memory evidence =
            guard.getApproval(address(child), _childMessageHash(child, bytes32(uint256(7))));
        assertEq(evidence.safeTx.to, address(signMessageLib));
        assertEq(evidence.safeTx.operation, uint8(Enum.Operation.DelegateCall));
        assertEq(evidence.safeTx.value, 0);
        assertEq(evidence.safeTx.data, data);
        assertEq(evidence.safeTx.safeTxGas, 0);
        assertEq(evidence.safeTx.baseGas, 4242);
        assertEq(evidence.safeTx.gasPrice, 0);
        assertEq(evidence.safeTx.gasToken, address(0xCAFE));
        assertEq(evidence.safeTx.refundReceiver, address(0xF00D));
        assertEq(evidence.safeTx.nonce, nonce);
        assertEq(evidence.signatures, signatures);
        assertEq(
            child.getTransactionHash(
                evidence.safeTx.to,
                evidence.safeTx.value,
                evidence.safeTx.data,
                Enum.Operation(evidence.safeTx.operation),
                evidence.safeTx.safeTxGas,
                evidence.safeTx.baseGas,
                evidence.safeTx.gasPrice,
                evidence.safeTx.gasToken,
                payable(evidence.safeTx.refundReceiver),
                evidence.safeTx.nonce
            ),
            txHash
        );
    }

    function testFuzz_approval_extensionCannotTruncateEoaSignatures(uint256 retained) public {
        _checkExtensionBoundary(child, _signers(), retained);
    }

    function testFuzz_approval_extensionCannotTruncateNestedSignatures(uint256 retained) public {
        Signer[] memory signers = new Signer[](2);
        signers[0] = _eoa(KEY_A);
        uint256[] memory keys = new uint256[](2);
        keys[0] = KEY_B;
        keys[1] = KEY_C;
        signers[1] = _child(child, keys);
        _checkExtensionBoundary(parent, signers, retained);
    }

    function testFuzz_approval_extensionCannotTruncateEmptyContractSignature(uint256 retained) public {
        bytes memory data = _signMessageCall(bytes32(uint256(7)));
        bytes32 approvalHash = _txHash(parent, address(signMessageLib), 0, data, Enum.Operation.DelegateCall);
        _approve(child, _signers(), approvalHash);
        Signer[] memory signers = new Signer[](2);
        signers[0] = _eoa(KEY_A);
        signers[1] = _approvedChild(child);
        _checkExtensionBoundary(parent, signers, retained);
    }

    function _checkExtensionBoundary(Safe approving, Signer[] memory signers, uint256 retained) internal {
        bytes32 message = bytes32(uint256(7));
        bytes memory data = _signMessageCall(message);
        bytes memory sigs = _signFor(approving, signers, address(signMessageLib), 0, data, Enum.Operation.DelegateCall);
        retained = bound(retained, 0, sigs.length - 1);
        bytes memory poisoned = abi.encodePacked(sigs, uint256(sigs.length - retained), POLICY_CONTEXT_TYPE);
        uint256 nonce = approving.nonce();
        bytes32 messageHash = _childMessageHash(approving, message);
        vm.expectRevert(ICrossecuteGuard.SignatureExtensionOverlap.selector);
        _execWith(approving, address(signMessageLib), 0, data, Enum.Operation.DelegateCall, poisoned);
        assertEq(approving.nonce(), nonce);
        assertEq(approving.signedMessages(messageHash), 0);
        vm.expectRevert(
            abi.encodeWithSelector(ICrossecuteGuard.ApprovalNotFound.selector, address(approving), messageHash)
        );
        guard.getApproval(address(approving), messageHash);

        assertTrue(
            _execWith(
                approving,
                address(signMessageLib),
                0,
                data,
                Enum.Operation.DelegateCall,
                _withPolicyContext(sigs, hex"0102")
            )
        );
        assertEq(guard.getApproval(address(approving), messageHash).signatures, sigs);
        assertEq(approving.signedMessages(messageHash), 1);
    }

    function test_approval_overlappingReplacementPreservesEvidence() public {
        bytes32 message = bytes32(uint256(7));
        bytes32 messageHash = _approve(child, _signers(), message);
        bytes memory previous = abi.encode(guard.getApproval(address(child), messageHash));
        bytes memory data = _signMessageCall(message);
        bytes memory sigs = _signFor(child, _signers(), address(signMessageLib), 0, data, Enum.Operation.DelegateCall);
        uint256 nonce = child.nonce();
        vm.expectRevert(ICrossecuteGuard.SignatureExtensionOverlap.selector);
        _execWith(
            child,
            address(signMessageLib),
            0,
            data,
            Enum.Operation.DelegateCall,
            abi.encodePacked(sigs, uint256(sigs.length), POLICY_CONTEXT_TYPE)
        );
        assertEq(child.nonce(), nonce);
        assertEq(abi.encode(guard.getApproval(address(child), messageHash)), previous);
    }

    function test_approval_attachedToParentDispatch() public {
        bytes32 parentTxHash = _parentDispatchHash();
        uint256 approvalNonce = child.nonce();
        _approve(child, _signers(), parentTxHash);
        bytes32 messageHash = _childMessageHash(child, parentTxHash);
        parentTransmitter.attachApproval(address(child), messageHash);

        Signer[] memory signers = new Signer[](2);
        signers[0] = _eoa(KEY_A);
        signers[1] = _approvedChild(child);
        bytes memory parentSigs = _sign(signers, parentTxHash);
        assertTrue(_execWith(parent, address(parentTransmitter), 0, _dispatchData(), Enum.Operation.Call, parentSigs));

        assertEq(parentTransmitter.lastSafeTxHash(), parentTxHash);
        assertEq(parentTransmitter.lastSignatures(), parentSigs);
        assertEq(parentTransmitter.lastApprovalNonces(0), approvalNonce);
        // Consuming the parent's dispatch leaves the child's evidence in place.
        assertEq(guard.getApproval(address(child), messageHash).safeTx.nonce, approvalNonce);
    }

    function test_approval_persistsAcrossLaterTransactions() public {
        bytes32 messageHash = _approve(child, _signers(), bytes32(uint256(7)));
        ICrossecuteGuard.SignedSafeTx memory first = guard.getApproval(address(child), messageHash);
        _exec(child, _signers(), address(0xBEEF), 0, "", Enum.Operation.Call);
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 30 days);
        assertEq(abi.encode(guard.getApproval(address(child), messageHash)), abi.encode(first));
    }

    function test_approval_laterApprovalReplaces() public {
        Signer[] memory three = new Signer[](3);
        three[0] = _eoa(KEY_A);
        three[1] = _eoa(KEY_B);
        three[2] = _eoa(KEY_C);
        bytes32 messageHash = _approve(child, three, bytes32(uint256(7)));
        assertEq(guard.getApproval(address(child), messageHash).signatures.length, 195);

        uint256 nonce = child.nonce();
        bytes memory data = _signMessageCall(bytes32(uint256(7)));
        bytes memory sigs = _signFor(child, _signers(), address(signMessageLib), 0, data, Enum.Operation.DelegateCall);
        _execWith(child, address(signMessageLib), 0, data, Enum.Operation.DelegateCall, sigs);

        ICrossecuteGuard.SignedSafeTx memory evidence = guard.getApproval(address(child), messageHash);
        assertEq(evidence.safeTx.nonce, nonce);
        assertEq(evidence.signatures, sigs);
    }

    function test_approval_containingRevertRollsBackWriteAndReplacement() public {
        Reverter reverter = new Reverter();
        bytes32 messageHash = _childMessageHash(child, bytes32(uint256(7)));
        bytes memory execCall = _approvalExecCall(child, _signers(), bytes32(uint256(7)), child.nonce());
        vm.expectRevert(Reverter.RolledBack.selector);
        reverter.run(child, execCall);
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.ApprovalNotFound.selector, address(child), messageHash));
        guard.getApproval(address(child), messageHash);

        _approve(child, _signers(), bytes32(uint256(7)));
        uint256 kept = guard.getApproval(address(child), messageHash).safeTx.nonce;
        execCall = _approvalExecCall(child, _signers(), bytes32(uint256(7)), child.nonce());
        vm.expectRevert(Reverter.RolledBack.selector);
        reverter.run(child, execCall);
        assertEq(guard.getApproval(address(child), messageHash).safeTx.nonce, kept);
    }

    /// @dev One `ApprovalCached` from the guard per write, a replacement included, and none when
    ///      nothing is cached.
    function test_approval_emitsApprovalCachedOncePerWrite() public {
        bytes32 messageHash = _childMessageHash(child, bytes32(uint256(7)));
        for (uint256 i = 0; i < 2; ++i) {
            vm.recordLogs();
            _approve(child, _signers(), bytes32(uint256(7)));
            assertEq(_approvalCachedCount(address(child), messageHash), 1);
        }

        vm.recordLogs();
        _exec(child, _signers(), address(fake), 0, _signMessageCall(bytes32(uint256(7))), Enum.Operation.Call);
        assertEq(_approvalCachedCount(address(child), messageHash), 0);
    }

    /// @dev Recognition ignores the target, so a cache entry does not show the flag was written.
    function test_approval_targetNotChecked() public {
        bytes memory data = _signMessageCall(bytes32(uint256(7)));
        _exec(child, _signers(), address(fake), 0, data, Enum.Operation.DelegateCall);
        bytes32 messageHash = _childMessageHash(child, bytes32(uint256(7)));
        assertEq(guard.getApproval(address(child), messageHash).safeTx.to, address(fake));
        assertEq(child.signedMessages(messageHash), 0);
    }

    function test_approval_callOperationNotCached() public {
        bytes memory data = _signMessageCall(bytes32(uint256(7)));
        // A CALL to the real library would revert, since it reads its own domain separator.
        assertTrue(_exec(child, _signers(), address(fake), 0, data, Enum.Operation.Call));
        bytes32 messageHash = _childMessageHash(child, bytes32(uint256(7)));
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.ApprovalNotFound.selector, address(child), messageHash));
        guard.getApproval(address(child), messageHash);
    }

    function test_approval_malformedCalldataReverts() public {
        bytes memory data = abi.encodePacked(SignMessageLib.signMessage.selector, uint8(1));
        bytes memory sigs = _signFor(child, _signers(), address(fake), 0, data, Enum.Operation.DelegateCall);
        // `abi.decode` fails with no revert data; the Safe and policy paths all revert with data,
        // and the same target with well-formed calldata succeeds in test_approval_targetNotChecked.
        vm.expectRevert(bytes(""));
        _execWith(child, address(fake), 0, data, Enum.Operation.DelegateCall, sigs);
    }

    function test_approval_scopedByChild() public {
        Safe sibling = _newEoaSafe();
        _install(sibling, _signers(), guard, _childConfig(), false);
        bytes32 childHash = _approve(child, _signers(), bytes32(uint256(7)));
        bytes32 siblingHash = _approve(sibling, _signers(), bytes32(uint256(7)));
        assertTrue(childHash != siblingHash);
        assertEq(guard.getApproval(address(child), childHash).safeTx.nonce, child.nonce() - 1);
        assertEq(guard.getApproval(address(sibling), siblingHash).safeTx.nonce, sibling.nonce() - 1);
        vm.expectRevert(abi.encodeWithSelector(ICrossecuteGuard.ApprovalNotFound.selector, address(sibling), childHash));
        guard.getApproval(address(sibling), childHash);
    }

    /// @dev Counts the guard's recorded `ApprovalCached` logs, requiring each to name `childSafe` and
    ///      `messageHash` in its topics and carry no data.
    function _approvalCachedCount(address childSafe, bytes32 messageHash) internal returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(guard) || logs[i].topics[0] != ICrossecuteGuard.ApprovalCached.selector) {
                continue;
            }
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(childSafe))));
            assertEq(logs[i].topics[2], messageHash);
            assertEq(logs[i].data.length, 0);
            ++count;
        }
    }

    function _childConfig() internal view returns (SafePolicyGuard.Configuration[] memory configs) {
        SafePolicyGuard.Configuration[] memory base = _defaultConfig();
        configs = new SafePolicyGuard.Configuration[](base.length + 1);
        for (uint256 i = 0; i < base.length; ++i) {
            configs[i] = base[i];
        }
        configs[base.length] =
            _config(address(fake), FakeSignLib.signMessage.selector, Operation.DELEGATECALL, address(allowPolicy));
    }

    function _parentDispatchHash() internal view returns (bytes32) {
        return _txHash(parent, address(parentTransmitter), 0, _dispatchData(), Enum.Operation.Call);
    }

    /// @dev Safe 1.5.0 asks a contract owner to validate `abi.encode(parentTxHash)`.
    function _signMessageCall(bytes32 parentTxHash) internal pure returns (bytes memory) {
        return abi.encodeCall(SignMessageLib.signMessage, (abi.encode(parentTxHash)));
    }

    function _childMessageHash(Safe safe_, bytes32 parentTxHash) internal view returns (bytes32) {
        return handler.getMessageHashForSafe(safe_, abi.encode(parentTxHash));
    }

    function _approve(Safe safe_, Signer[] memory signers, bytes32 parentTxHash) internal returns (bytes32) {
        _exec(safe_, signers, address(signMessageLib), 0, _signMessageCall(parentTxHash), Enum.Operation.DelegateCall);
        return _childMessageHash(safe_, parentTxHash);
    }

    function _approvalExecCall(Safe safe_, Signer[] memory signers, bytes32 parentTxHash, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes memory data = _signMessageCall(parentTxHash);
        bytes memory sigs =
            _sign(signers, _txHashAt(safe_, address(signMessageLib), 0, data, Enum.Operation.DelegateCall, nonce));
        return abi.encodeCall(
            Safe.execTransaction,
            (
                address(signMessageLib),
                0,
                data,
                Enum.Operation.DelegateCall,
                0,
                0,
                0,
                address(0),
                payable(address(0)),
                sigs
            )
        );
    }
}
